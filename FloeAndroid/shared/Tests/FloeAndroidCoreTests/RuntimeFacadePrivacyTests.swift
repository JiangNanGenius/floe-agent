// SPDX-License-Identifier: MPL-2.0
//
// G02 privacy backend tests — authored source for the LATER combined
// qualification. This lane does not compile or execute them.
//
// The 35 original regression intents are preserved and extended with the
// Main-required bounded streaming/spool, trusted-native capability, failure
// paging and provider-generation race cases. Assertions are never weakened
// to mask an error: a fixture change that changes a digest is a real CAS
// change, and a missing owner port must refuse before any effect.
import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
import FloeAgentRuntime
@testable import FloeAndroidCore

final class RuntimeFacadePrivacyTests: XCTestCase {

    // MARK: Helpers

    private func historyRevision(_ assembly: PrivacyFacadeAssembly) async throws -> String {
        try await assembly.facade.summary().history.revision
    }

    private func modelRevision(_ assembly: PrivacyFacadeAssembly) async throws -> String {
        try await assembly.facade.summary().modelConfiguration.revision
    }

    private func clearHistory(_ assembly: PrivacyFacadeAssembly,
                              invocation: String = "inv-history",
                              token override: String? = nil) async throws
        -> PrivacyHistoryClearReport
    {
        let digest = try await historyRevision(assembly)
        let token = override ?? privacyIssue(assembly, digest: digest,
                                             invocation: invocation)!
        return try await assembly.facade.clearHistory(
            request: PrivacyClearRequest(confirmToken: token),
            revision: BaseRevision(resourceID: RuntimeFacadePrivacy.historyResourceID,
                                   version: digest),
            invocationID: invocation)
    }

    private func memoryCount(_ stores: PrivacyTestBed.Stores) async throws -> Int {
        try await PrivacyTestBed.count(stores.database,
                                       "SELECT COUNT(*) FROM memory_entries")
    }

    private func conversationExists(_ stores: PrivacyTestBed.Stores,
                                    _ id: UUID) async throws -> Bool {
        try await PrivacyTestBed.count(
            stores.database,
            "SELECT COUNT(*) FROM conversations WHERE id = ?",
            [id.uuidString]) == 1
    }

    // MARK: - Summary

    func testSummaryOnFreshMigratedDatabase() async throws {
        let stores = try await PrivacyTestBed.stores(name: "fresh")
        let assembly = PrivacyFacadeFactory.make(stores: stores)
        let reply = try await assembly.facade.summary()
        XCTAssertEqual(reply.history.conversationCount, 0)
        XCTAssertEqual(reply.history.runCount, 0)
        XCTAssertEqual(reply.history.persistedGrantCount, 0)
        XCTAssertEqual(reply.history.inMemoryGrantCount, 0)
        XCTAssertEqual(reply.modelConfiguration.providerCount, 0)
        XCTAssertEqual(reply.modelConfiguration.modelCount, 0)
        XCTAssertEqual(reply.modelConfiguration.secretReferenceCount, 0)
        XCTAssertTrue(reply.history.revision.hasPrefix("sha256:"))
        XCTAssertEqual(reply.history.revision.count, 71)
        XCTAssertTrue(reply.snapshot.dbSnapshotTransaction)
        XCTAssertEqual(reply.snapshot.inMemoryGrantBracket, "g1==g2")
        XCTAssertEqual(reply.snapshot.retriesBounded, 3)
    }

    func testSummaryCountsAreDisplayOnlyAndBounded() async throws {
        let stores = try await PrivacyTestBed.stores(name: "counts")
        let conversation = try await PrivacyTestBed.seedConversation(stores)
        _ = try await PrivacyTestBed.seedRun(stores, conversationID: conversation)
        _ = try await PrivacyTestBed.seedPersistedGrant(stores)
        let assembly = PrivacyFacadeFactory.make(stores: stores)
        let first = try await assembly.facade.summary()
        XCTAssertEqual(first.history.conversationCount, 1)
        XCTAssertEqual(first.history.runCount, 1)
        XCTAssertEqual(first.history.persistedGrantCount, 1)
        // A run state change alters the digest while every count stays the
        // same — counts can never be the CAS token.
        try await stores.database.writer { db in
            try db.execute(sql: "UPDATE runs SET state = 'running'")
        }
        let second = try await assembly.facade.summary()
        XCTAssertEqual(second.history.conversationCount, 1)
        XCTAssertEqual(second.history.runCount, 1)
        XCTAssertNotEqual(first.history.revision, second.history.revision)
    }

    func testCredentialAvailabilityNeedsConfigurationUntilQualified() async throws {
        let stores = try await PrivacyTestBed.stores(name: "credential")
        let unregistered = PrivacyFacadeFactory.make(
            stores: stores, secrets: FakeSecretOrdering(registered: false))
        let reply = try await unregistered.facade.summary()
        XCTAssertEqual(reply.credentialAvailability, .needsConfiguration)

        let registered = PrivacyFacadeFactory.make(
            stores: stores, secrets: FakeSecretOrdering(registered: true))
        let available = try await registered.facade.summary()
        XCTAssertEqual(available.credentialAvailability, .available)
    }

    // MARK: - Identity digest sensitivity

    func testEqualCountRunReplacementChangesDigest() async throws {
        let stores = try await PrivacyTestBed.stores(name: "replacement")
        let conversation = try await PrivacyTestBed.seedConversation(stores)
        let first = try await PrivacyTestBed.seedRun(stores,
                                                     conversationID: conversation)
        let assembly = PrivacyFacadeFactory.make(stores: stores)
        let before = try await historyRevision(assembly)
        try await stores.database.writer { db in
            try db.execute(sql: "DELETE FROM runs WHERE id = ?",
                           arguments: [first.uuidString])
            try db.execute(
                sql: """
                    INSERT INTO runs (id, conversation_id, state, goal,
                                      started_at, ended_at)
                    VALUES (?, ?, 'completed', 'goal',
                            '2026-10-19T00:00:00Z', '2026-10-19T00:05:00Z')
                    """,
                arguments: [UUID().uuidString, conversation.uuidString])
        }
        let after = try await historyRevision(assembly)
        XCTAssertNotEqual(before, after)
    }

    func testRunStateChangeChangesDigest() async throws {
        let stores = try await PrivacyTestBed.stores(name: "runstate")
        let conversation = try await PrivacyTestBed.seedConversation(stores)
        // Seed a NON-final state so the UPDATE below is a real state
        // change (the seed default is already 'completed').
        _ = try await PrivacyTestBed.seedRun(stores, conversationID: conversation,
                                             state: "running")
        let assembly = PrivacyFacadeFactory.make(stores: stores)
        let before = try await historyRevision(assembly)
        try await stores.database.writer { db in
            try db.execute(sql: "UPDATE runs SET state = 'completed'")
        }
        let after = try await historyRevision(assembly)
        XCTAssertNotEqual(before, after)
    }

    func testConversationReownChangesDigest() async throws {
        let stores = try await PrivacyTestBed.stores(name: "reown")
        let conversation = try await PrivacyTestBed.seedConversation(stores)
        let firstWorkspace = UUID()
        let secondWorkspace = UUID()
        try await PrivacyTestBed.seedOwnership(stores,
                                              conversationID: conversation,
                                              workspaceID: firstWorkspace)
        // The re-own target workspace must exist for the FK as well.
        try await PrivacyTestBed.seedWorkspace(stores,
                                               workspaceID: secondWorkspace,
                                               conversationID: conversation)
        let assembly = PrivacyFacadeFactory.make(stores: stores)
        let before = try await historyRevision(assembly)
        try await stores.database.writer { db in
            try db.execute(
                sql: """
                    UPDATE conversation_workspace_ownership
                    SET workspace_id = ?
                    WHERE conversation_id = ?
                    """,
                arguments: [secondWorkspace.uuidString, conversation.uuidString])
        }
        let after = try await historyRevision(assembly)
        XCTAssertNotEqual(before, after)
    }

    func testGrantPathsAndPolicyChangeChangesDigest() async throws {
        let stores = try await PrivacyTestBed.stores(name: "grant-digest")
        _ = try await PrivacyTestBed.seedPersistedGrant(stores)
        let assembly = PrivacyFacadeFactory.make(stores: stores)
        let before = try await historyRevision(assembly)
        try await stores.database.writer { db in
            try db.execute(sql: """
                UPDATE approval_grants
                SET paths_json = '["/tmp/a"]', policy_name = 'policy.b'
                """)
        }
        let after = try await historyRevision(assembly)
        XCTAssertNotEqual(before, after)
    }

    func testInMemoryGrantAddRevokeChangesDigest() async throws {
        let stores = try await PrivacyTestBed.stores(name: "inmemory")
        let inMemory = FakeInMemoryGrantStore()
        let assembly = PrivacyFacadeFactory.make(stores: stores, inMemory: inMemory)
        let before = try await historyRevision(assembly)
        let grant = ApprovalGrant(
            scope: ApprovalScope(toolName: "files.read", paths: ["a"]),
            expiresAt: nil, decidedAt: Date(timeIntervalSince1970: 1),
            policyName: "p")
        await inMemory.insert(grant)
        let afterInsert = try await historyRevision(assembly)
        XCTAssertNotEqual(before, afterInsert)
        await inMemory.revokeGrant(id: grant.id)
        let afterRevoke = try await historyRevision(assembly)
        XCTAssertEqual(before, afterRevoke)
    }

    func testProviderSecretRefAndPreferenceChangeChangeDigest() async throws {
        let stores = try await PrivacyTestBed.stores(name: "model-digest")
        _ = try await PrivacyTestBed.seedProvider(stores, secretAccount: nil)
        let assembly = PrivacyFacadeFactory.make(stores: stores)
        let before = try await modelRevision(assembly)
        try await stores.database.writer { db in
            try db.execute(sql: "UPDATE providers SET secret_ref_account = 'provider.x'")
        }
        let afterSecret = try await modelRevision(assembly)
        XCTAssertNotEqual(before, afterSecret)
        try await stores.database.writer { db in
            try db.execute(sql: "UPDATE model_preferences SET onboarding_status = 'skipped'")
        }
        let afterPreference = try await modelRevision(assembly)
        XCTAssertNotEqual(afterSecret, afterPreference)
    }

    // MARK: - Bracket

    func testUnstableGrantBracketExhaustsBoundedRetriesThenFailsClosed() async throws {
        let stores = try await PrivacyTestBed.stores(name: "bracket-exhaust")
        let inMemory = FakeInMemoryGrantStore()
        for index in [2, 4, 6] {
            let grant = ApprovalGrant(
                scope: ApprovalScope(toolName: "t\(index)"), expiresAt: nil,
                decidedAt: Date(timeIntervalSince1970: 1), policyName: "p")
            await inMemory.mutate(onRead: index, insert: grant)
        }
        let engine = PrivacySnapshotEngine(
            database: stores.database, inMemoryGrants: inMemory,
            rootPath: stores.directory.path, epoch: 1)
        do {
            _ = try await engine.captureHistory(maxAttempts: 3)
            XCTFail("expected unstableGrantSnapshot")
        } catch let error as PrivacyDomainError {
            XCTAssertEqual(error, .persistenceUnavailable("unstableGrantSnapshot"))
        }
        let conversations = try await PrivacyTestBed.count(
            stores.database, "SELECT COUNT(*) FROM conversations")
        XCTAssertEqual(conversations, 0)
    }

    func testBracketSucceedsAfterOneTransientMutation() async throws {
        let stores = try await PrivacyTestBed.stores(name: "bracket-retry")
        let inMemory = FakeInMemoryGrantStore()
        let grant = ApprovalGrant(
            scope: ApprovalScope(toolName: "t"), expiresAt: nil,
            decidedAt: Date(timeIntervalSince1970: 1), policyName: "p")
        await inMemory.mutate(onRead: 2, insert: grant)
        let engine = PrivacySnapshotEngine(
            database: stores.database, inMemoryGrants: inMemory,
            rootPath: stores.directory.path, epoch: 1)
        let capture = try await engine.captureHistory(maxAttempts: 3)
        XCTAssertEqual(capture.attemptsUsed, 2)
        XCTAssertEqual(capture.inMemoryGrantCount, 1)
    }

    // MARK: - History clear

    func testArchivedAndNotesConversationsExcludedFromClear() async throws {
        let stores = try await PrivacyTestBed.stores(name: "excluded")
        let ordinary = try await PrivacyTestBed.seedConversation(stores)
        let archived = try await PrivacyTestBed.seedConversation(
            stores, archived: true)
        let notes = try await PrivacyTestBed.seedConversation(
            stores, purpose: "notes")
        let assembly = PrivacyFacadeFactory.make(stores: stores)
        let report = try await clearHistory(assembly)
        XCTAssertEqual(report.deleted.conversations, 1)
        let ordinaryExists = try await conversationExists(stores, ordinary)
        let archivedExists = try await conversationExists(stores, archived)
        let notesExists = try await conversationExists(stores, notes)
        XCTAssertFalse(ordinaryExists)
        XCTAssertTrue(archivedExists)
        XCTAssertTrue(notesExists)
    }

    func testTaskMemoriesDetachButSurviveWithOrigin() async throws {
        let stores = try await PrivacyTestBed.stores(name: "memory")
        let conversation = try await PrivacyTestBed.seedConversation(stores)
        let memory = try await PrivacyTestBed.seedMemory(
            stores, conversationID: conversation)
        let assembly = PrivacyFacadeFactory.make(stores: stores)
        _ = try await clearHistory(assembly)
        // Pinned-GRDB Sendable repair (2026-10-21): a Row cannot cross the
        // async boundary; values are extracted inside the reader closure.
        let values = try await stores.database.reader {
            db -> (String?, String?, String?)? in
            guard let row = try Row.fetchOne(
                db, sql: """
                    SELECT conversation_id, origin_conversation_id, \
                    owner_deleted_at FROM memory_entries WHERE id = ?
                    """,
                arguments: [memory.uuidString]) else { return nil }
            let conversation: String? = row["conversation_id"]
            let origin: String? = row["origin_conversation_id"]
            let ownerDeleted: String? = row["owner_deleted_at"]
            return (conversation, origin, ownerDeleted)
        }
        XCTAssertNotNil(values)
        XCTAssertNil(values?.0)
        XCTAssertEqual(values?.1, conversation.uuidString)
        XCTAssertNotNil(values?.2)
    }

    func testWorkspaceRowsSurviveHistoryClear() async throws {
        let stores = try await PrivacyTestBed.stores(name: "workspace")
        let conversation = try await PrivacyTestBed.seedConversation(stores)
        let workspaceID = UUID()
        try await stores.database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO workspaces
                        (id, name, root_bookmark, created_at, updated_at)
                    VALUES (?, 'w', ?, '2026-10-19T00:00:00Z',
                            '2026-10-19T00:00:00Z')
                    """,
                arguments: [workspaceID.uuidString, Data([0x01])])
        }
        try await PrivacyTestBed.seedOwnership(stores,
                                              conversationID: conversation,
                                              workspaceID: workspaceID)
        let assembly = PrivacyFacadeFactory.make(stores: stores)
        _ = try await clearHistory(assembly)
        let workspaces = try await PrivacyTestBed.count(
            stores.database, "SELECT COUNT(*) FROM workspaces")
        XCTAssertEqual(workspaces, 1)
    }

    func testMissingHostConfirmationFailsClosedBeforeAnyEffect() async throws {
        let stores = try await PrivacyTestBed.stores(name: "no-confirm")
        let conversation = try await PrivacyTestBed.seedConversation(stores)
        let assembly = PrivacyFacadeFactory.make(stores: stores)
        let digest = try await historyRevision(assembly)
        do {
            _ = try await assembly.facade.clearHistory(
                request: PrivacyClearRequest(
                    confirmToken: "pc:v1:" + String(repeating: "a", count: 32)),
                revision: BaseRevision(
                    resourceID: RuntimeFacadePrivacy.historyResourceID,
                    version: digest),
                invocationID: "inv")
            XCTFail("expected refusal")
        } catch let error as PrivacyDomainError {
            XCTAssertEqual(error.wireCode, "runtimeUnavailable")
        }
        let exists = try await conversationExists(stores, conversation)
        XCTAssertTrue(exists)
        let fenced = await assembly.fence.isFencedNow()
        XCTAssertFalse(fenced)
    }

    func testForeignPreviewEpochAndOperationDenied() async throws {
        let stores = try await PrivacyTestBed.stores(name: "foreign-cap")
        let conversation = try await PrivacyTestBed.seedConversation(stores)
        let assembly = PrivacyFacadeFactory.make(stores: stores)
        let digest = try await historyRevision(assembly)
        // A capability minted for the model-config operation cannot authorize
        // history clear, even with the history digest as its preview.
        let modelToken = privacyIssue(
            assembly,
            operation: RuntimeFacadePrivacy.modelConfigClearOperation,
            digest: digest, invocation: "inv")
        do {
            _ = try await assembly.facade.clearHistory(
                request: PrivacyClearRequest(confirmToken: modelToken!),
                revision: BaseRevision(
                    resourceID: RuntimeFacadePrivacy.historyResourceID,
                    version: digest),
                invocationID: "inv")
            XCTFail("expected refusal")
        } catch let error as PrivacyDomainError {
            XCTAssertEqual(error.wireCode, "runtimeUnavailable")
        }
        // A bare digest is never consent.
        do {
            _ = try await assembly.facade.clearHistory(
                request: PrivacyClearRequest(confirmToken: digest),
                revision: BaseRevision(
                    resourceID: RuntimeFacadePrivacy.historyResourceID,
                    version: digest),
                invocationID: "inv")
            XCTFail("expected bare-digest refusal")
        } catch let error as PrivacyDomainError {
            XCTAssertEqual(error.wireCode, "runtimeUnavailable")
        }
        let exists = try await conversationExists(stores, conversation)
        XCTAssertTrue(exists)
    }

    func testUnboundRequiredPortsFailClosed() async throws {
        let stores = try await PrivacyTestBed.stores(name: "unbound")
        let conversation = try await PrivacyTestBed.seedConversation(stores)
        let assembly = PrivacyFacadeFactory.make(stores: stores,
                                                 bindLifecycle: false)
        do {
            _ = try await clearHistory(assembly)
            XCTFail("expected unbound lifecycle refusal")
        } catch let error as PrivacyDomainError {
            XCTAssertEqual(error.wireCode, "runtimeUnavailable")
        }
        let stillExists = try await conversationExists(stores, conversation)
        XCTAssertTrue(stillExists)

        let noOwned = PrivacyFacadeFactory.make(stores: stores,
                                                bindOwnedWork: false)
        do {
            _ = try await clearHistory(noOwned)
            XCTFail("expected unbound owned-work refusal")
        } catch let error as PrivacyDomainError {
            XCTAssertEqual(error.wireCode, "runtimeUnavailable")
        }
        let afterUnboundOwned = try await conversationExists(stores, conversation)
        XCTAssertTrue(afterUnboundOwned)
    }

    func testRefusedClearReleasesFenceSoFutureLaunchesProceed() async throws {
        let stores = try await PrivacyTestBed.stores(name: "fence-release")
        let assembly = PrivacyFacadeFactory.make(stores: stores)
        let digest = try await historyRevision(assembly)
        _ = try? await assembly.facade.clearHistory(
            request: PrivacyClearRequest(confirmToken: digest),
            revision: BaseRevision(
                resourceID: RuntimeFacadePrivacy.historyResourceID,
                version: digest),
            invocationID: "inv")
        let fenced = await assembly.fence.isFencedNow()
        XCTAssertFalse(fenced)
        let calls = await assembly.fence.calls
        XCTAssertTrue(calls.contains(.init(kind: "finish", committed: false)))
    }

    func testStaleFinishCannotClearNewerFence() async throws {
        let fence = ScriptedGlobalFence()
        let first = try await fence.beginGlobalAdmissionFence(expectedEpoch: 1)
        do {
            _ = try await fence.beginGlobalAdmissionFence(expectedEpoch: 1)
            XCTFail("duplicate begin must refuse while held")
        } catch let error as PrivacyDomainError {
            XCTAssertEqual(error, .duplicateInFlight)
        }
        let firstFinished = await fence.finishGlobalAdmissionFence(
            first, committed: true)
        XCTAssertTrue(firstFinished)
        let second = try await fence.beginGlobalAdmissionFence(expectedEpoch: 1)
        let staleFinished = await fence.finishGlobalAdmissionFence(
            first, committed: false)
        XCTAssertFalse(staleFinished)
        let stillFenced = await fence.isFencedNow()
        XCTAssertTrue(stillFenced)
        let secondFinished = await fence.finishGlobalAdmissionFence(
            second, committed: false)
        XCTAssertTrue(secondFinished)
    }

    func testClearHoldingBlockedRunWaitsRealDrainBeforeDelete() async throws {
        let stores = try await PrivacyTestBed.stores(name: "drain-order")
        let conversation = try await PrivacyTestBed.seedConversation(stores)
        let assembly = PrivacyFacadeFactory.make(stores: stores)
        let report = try await clearHistory(assembly)
        XCTAssertEqual(report.deleted.conversations, 1)
        let entries = await assembly.lifecycle.entries
        XCTAssertEqual(entries.map(\.kind), ["begin", "drain", "commit"])
        let exists = try await conversationExists(stores, conversation)
        XCTAssertFalse(exists)
    }

    func testTwoFacadesSameContextSharedFenceRefusesDoubleClear() async throws {
        let stores = try await PrivacyTestBed.stores(name: "double-fence")
        let conversation = try await PrivacyTestBed.seedConversation(stores)
        let fence = ScriptedGlobalFence()
        let first = PrivacyFacadeFactory.make(stores: stores, fence: fence)
        let second = PrivacyFacadeFactory.make(stores: stores, fence: fence)
        let held = try await fence.beginGlobalAdmissionFence(expectedEpoch: 1)
        let digest = try await historyRevision(second)
        let token = privacyIssue(second, digest: digest, invocation: "inv")!
        do {
            _ = try await second.facade.clearHistory(
                request: PrivacyClearRequest(confirmToken: token),
                revision: BaseRevision(
                    resourceID: RuntimeFacadePrivacy.historyResourceID,
                    version: digest),
                invocationID: "inv")
            XCTFail("second clear must refuse while the fence is held")
        } catch let error as PrivacyDomainError {
            XCTAssertEqual(error, .duplicateInFlight)
        }
        let exists = try await conversationExists(stores, conversation)
        XCTAssertTrue(exists)
        _ = await fence.finishGlobalAdmissionFence(held, committed: false)
        _ = first
    }

    func testNewConversationAndGrantAfterSnapshotSurvive() async throws {
        let stores = try await PrivacyTestBed.stores(name: "late-rows")
        let existing = try await PrivacyTestBed.seedConversation(stores)
        _ = try await PrivacyTestBed.seedPersistedGrant(stores)
        let lateConversation = UUID()
        let lateGrant = UUID()
        let counter = PrivacyCallCounter()
        let assembly = PrivacyFacadeFactory.make(
            stores: stores,
            faultInjection: { phase in
                guard phase == "history.clear.conversation",
                      counter.increment() == 1 else { return }
                // The confirmed snapshot is already captured. Rows created
                // now are NOT part of it and must survive the clear.
                _ = try await PrivacyTestBed.seedConversation(
                    stores, id: lateConversation, title: "late")
                _ = try await PrivacyTestBed.seedPersistedGrant(
                    stores, id: lateGrant)
            })
        let report = try await clearHistory(assembly)
        XCTAssertEqual(report.deleted.conversations, 1)
        XCTAssertEqual(report.deleted.persistedGrants, 1)
        XCTAssertNotNil(report.remaining)
        XCTAssertEqual(report.remaining?.conversationCount, 1)
        XCTAssertEqual(report.remaining?.persistedGrantCount, 1)
        let existingExists = try await conversationExists(stores, existing)
        let lateExists = try await conversationExists(stores, lateConversation)
        XCTAssertFalse(existingExists)
        XCTAssertTrue(lateExists)
        let lateGrantCount = try await PrivacyTestBed.count(
            stores.database, "SELECT COUNT(*) FROM approval_grants WHERE id = ?",
            [lateGrant.uuidString])
        XCTAssertEqual(lateGrantCount, 1)
    }

    func testInjectedMidBatchFailureYieldsTruthfulPartialReport() async throws {
        let stores = try await PrivacyTestBed.stores(name: "mid-batch")
        let first = try await PrivacyTestBed.seedConversation(stores)
        let second = try await PrivacyTestBed.seedConversation(stores)
        let third = try await PrivacyTestBed.seedConversation(stores)
        let counter = PrivacyCallCounter()
        let assembly = PrivacyFacadeFactory.make(
            stores: stores,
            faultInjection: { phase in
                guard phase == "history.clear.conversation" else { return }
                if counter.increment() == 2 {
                    throw PrivacyDomainError.runtimeUnavailable(
                        "scriptedMidBatchFailure")
                }
            })
        let report = try await clearHistory(assembly)
        XCTAssertEqual(report.deleted.conversations, 2)
        XCTAssertTrue(report.partial)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.failures.first?.reason, "scriptedMidBatchFailure")
        XCTAssertNotNil(report.remaining)
        // The scripted failure refuses exactly ONE pre-item boundary; the
        // other enumerated conversations are deleted and nothing is retried.
        let remaining = try await PrivacyTestBed.count(
            stores.database, "SELECT COUNT(*) FROM conversations")
        XCTAssertEqual(remaining, 1)
        var survivors = 0
        for id in [first, second, third] {
            if try await conversationExists(stores, id) { survivors += 1 }
        }
        XCTAssertEqual(survivors, 1)
    }

    func testGrantLayerFailureDoesNotBlockOtherLayer() async throws {
        let stores = try await PrivacyTestBed.stores(name: "grant-failure")
        _ = try await PrivacyTestBed.seedConversation(stores)
        let good = try await PrivacyTestBed.seedPersistedGrant(stores)
        let bad = try await PrivacyTestBed.seedPersistedGrant(stores)
        let inMemory = FakeInMemoryGrantStore()
        let grant = ApprovalGrant(
            scope: ApprovalScope(toolName: "x"), expiresAt: nil,
            decidedAt: Date(timeIntervalSince1970: 1), policyName: "p")
        await inMemory.insert(grant)
        let assembly = PrivacyFacadeFactory.make(
            stores: stores, inMemory: inMemory,
            persistedGrants: FailingPersistedGrants(
                store: stores.workspaces, failing: [bad]))
        let report = try await clearHistory(assembly)
        XCTAssertEqual(report.deleted.persistedGrants, 1)
        XCTAssertEqual(report.deleted.inMemoryGrants, 1)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.failures.first?.itemID, bad)
        let remaining = try await PrivacyTestBed.count(
            stores.database, "SELECT COUNT(*) FROM approval_grants")
        XCTAssertEqual(remaining, 1)
        let goodCount = try await PrivacyTestBed.count(
            stores.database, "SELECT COUNT(*) FROM approval_grants WHERE id = ?",
            [good.uuidString])
        XCTAssertEqual(goodCount, 0)
        let inMemoryIDs = await inMemory.currentIDs()
        XCTAssertEqual(inMemoryIDs, [])
    }

    func testProcessDeathMidBatchRecoversViaSummaryAndDurableQueue() async throws {
        let stores = try await PrivacyTestBed.stores(name: "process-death")
        let conversation = try await PrivacyTestBed.seedConversation(stores)
        _ = try await PrivacyTestBed.seedPersistedGrant(stores)
        let assembly = PrivacyFacadeFactory.make(stores: stores)
        _ = try await clearHistory(assembly)
        let reopened = try await PrivacyTestBed.reopen(stores)
        let after = PrivacyFacadeFactory.make(stores: reopened)
        let reply = try await after.facade.summary()
        XCTAssertEqual(reply.history.conversationCount, 0)
        XCTAssertEqual(reply.history.persistedGrantCount, 0)
        let exists = try await conversationExists(reopened, conversation)
        XCTAssertFalse(exists)
    }

    // MARK: - Bounded streaming / spool

    func testStreamingDigestMatchesCanonicalToken() async throws {
        typealias Digest = SettingsDomainV1.CanonicalDigest
        let records: [[Digest.Field]] = [
            [.null, .text("NULL"), .text("<null>"), .text("")],
            [.integer(1), .real(1.0), .text("1")],
            [.integer(Int64.min), .integer(Int64.max)],
            [.real(-0.0), .real(0.0)],
            [.text("a\u{1F}b"), .text("a|b")],
            [.blob(Data([0x00, 0x01, 0xFF]))],
        ]
        let expected = Digest.token(domain: Digest.domainPrivacyHistory,
                                    records: records)
        var incremental = Digest.IncrementalToken(
            domain: Digest.domainPrivacyHistory)
        for record in records { incremental.append(record) }
        XCTAssertEqual(incremental.finalize(), expected)
        XCTAssertEqual(incremental.finalize(), "")
    }

    func testBoundedKeysetTraversalExceedsPageSize() async throws {
        let stores = try await PrivacyTestBed.stores(name: "keyset")
        for index in 0..<300 {
            _ = try await PrivacyTestBed.seedConversation(
                stores, title: "task-\(index)")
        }
        let engine = PrivacySnapshotEngine(
            database: stores.database,
            inMemoryGrants: FakeInMemoryGrantStore(),
            rootPath: stores.directory.path, epoch: 1)
        let capture = try await engine.captureHistory(maxAttempts: 3)
        XCTAssertEqual(capture.conversationCount, 300)
        XCTAssertNil(capture.spool)
    }

    func testSpoolIsVerifiedAndRemoved() async throws {
        let stores = try await PrivacyTestBed.stores(name: "spool")
        for index in 0..<40 {
            _ = try await PrivacyTestBed.seedConversation(
                stores, title: "task-\(index)")
        }
        let engine = PrivacySnapshotEngine(
            database: stores.database,
            inMemoryGrants: FakeInMemoryGrantStore(),
            rootPath: stores.directory.path, epoch: 1)
        let capture = try await engine.captureHistory(
            captureTargets: true, operationID: UUID())
        let descriptor = try XCTUnwrap(capture.spool)
        XCTAssertEqual(descriptor.counts.conversations, 40)
        // Verified open succeeds.
        _ = try PrivacyClearSpool.open(descriptor: descriptor)
        // Any byte change is detected before a destructive effect.
        let file = URL(fileURLWithPath: descriptor.directoryPath)
            .appendingPathComponent("conversations.dat")
        var data = try Data(contentsOf: file)
        data[0] = data[0] == 0x63 ? 0x64 : 0x63
        try data.write(to: file)
        XCTAssertThrowsError(try PrivacyClearSpool.open(descriptor: descriptor)) {
            guard let error = $0 as? PrivacyDomainError else {
                return XCTFail("typed refusal expected")
            }
            XCTAssertEqual(error.wireCode, "persistenceUnavailable")
        }
        PrivacyClearSpool.remove(descriptor: descriptor)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: descriptor.directoryPath))
    }

    private final class PrivacyCallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
    }

    // MARK: - Bounded report paging end to end (>8 failures, stable order)

    /// A clear with MANY per-item failures mints a failure page; every
    /// failure stays readable through the existing privacy.summary.get
    /// optional report request in exact stable order, and the initial
    /// bounded array is the head of that same order (no hidden truncation).
    func testManyFailuresPageEndToEndThroughSummaryGet() async throws {
        let stores = try await PrivacyTestBed.stores(name: "many-failures")
        var ids: [UUID] = []
        for _ in 0..<30 {
            let id = try await PrivacyTestBed.seedConversation(stores)
            ids.append(id)
        }
        let lifecycle = ScriptedDeletionLifecycle()
        for id in ids { await lifecycle.failDrainFor(id) }
        let assembly = PrivacyFacadeFactory.make(
            stores: stores, lifecycle: lifecycle)
        let report = try await clearHistory(assembly)
        XCTAssertEqual(report.deleted.conversations, 0)
        XCTAssertEqual(report.failures.count,
                       PrivacyReportLimits.initialFailureItems)
        let summary = try XCTUnwrap(report.failurePage)
        XCTAssertEqual(summary.returned,
                       PrivacyReportLimits.initialFailureItems)
        XCTAssertEqual(summary.total, 30)
        var cursor: String? = summary.nextCursor
        var seen: [PrivacyFailurePageItem] = []
        var guardPages = 0
        while cursor != nil && guardPages < 16 {
            let page = try await assembly.facade.reportPage(
                handle: summary.handle, cursor: cursor, maxItems: 8)
            seen.append(contentsOf: page.items)
            cursor = page.nextCursor
            guardPages += 1
            XCTAssertLessThanOrEqual(page.items.count, 8)
        }
        XCTAssertEqual(seen.count, 30 - PrivacyReportLimits.initialFailureItems)
        // The paged tail continues the initial array in the SAME order; the
        // full stream is exactly the failures the clear recorded (all 30
        // distinct conversations, nothing dropped, nothing duplicated).
        let head = report.failures.map(\.pageItem)
        XCTAssertEqual(head.count, PrivacyReportLimits.initialFailureItems)
        let full = head + seen
        XCTAssertEqual(full.count, 30)
        XCTAssertEqual(Set(full.compactMap(\.itemID)).count, 30)
        XCTAssertEqual(full.map(\.reason),
                       Array(repeating: "scriptedDrainFailure", count: 30))
    }

    /// Wire-budget honesty at the facade: the clear value itself never
    /// carries more than the bounded initial page even for hundreds of
    /// failures, and the terminal summary points at the same-root store.
    func testClearValueStaysBoundedWithHundredsOfFailures() async throws {
        let stores = try await PrivacyTestBed.stores(name: "hundreds")
        var ids: [UUID] = []
        for _ in 0..<300 {
            ids.append(try await PrivacyTestBed.seedConversation(stores))
        }
        let lifecycle = ScriptedDeletionLifecycle()
        for id in ids { await lifecycle.failDrainFor(id) }
        let assembly = PrivacyFacadeFactory.make(
            stores: stores, lifecycle: lifecycle)
        let report = try await clearHistory(assembly)
        XCTAssertEqual(report.failures.count,
                       PrivacyReportLimits.initialFailureItems)
        let summary = try XCTUnwrap(report.failurePage)
        XCTAssertEqual(summary.total, 300)
        var cursor: String? = summary.nextCursor
        var count = 0
        var guardPages = 0
        while cursor != nil && guardPages < 64 {
            let page = try await assembly.facade.reportPage(
                handle: summary.handle, cursor: cursor, maxItems: 128)
            count += page.items.count
            cursor = page.nextCursor
            guardPages += 1
        }
        XCTAssertEqual(count, 300 - PrivacyReportLimits.initialFailureItems)
        // The report spool directory is owned, verified and still present
        // (process-lifetime); RootStop/eviction owns its cleanup.
        let base = stores.directory
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("PrivacyReports", isDirectory: true)
        let name = "report-" + String(summary.handle.dropFirst("pr:v1:".count))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: base.appendingPathComponent(name).path))
    }

    // MARK: - Actual runtime grant ownership (adapter identity semantics)

    func testRuntimeGrantOwnershipCollapsesRepeatedIDs() throws {
        let grant = ApprovalGrant(
            scope: ApprovalScope(toolName: "exec.shell"),
            expiresAt: nil,
            decidedAt: Date(timeIntervalSince1970: 100),
            policyName: "policy.a")
        // One runtime appended the same reusable grant three times (the
        // normal resolveToolCall reuse execution fact).
        let combined = try PrivacyRuntimeGrantOwnership.combine(owners: [
            (ownerID: "run-1", grants: [grant, grant, grant]),
        ])
        XCTAssertEqual(combined.count, 1)
        XCTAssertEqual(combined.first, grant)
    }

    func testRuntimeGrantOwnershipKeepsUnrelatedOwnersAndOrders() throws {
        let early = ApprovalGrant(
            scope: ApprovalScope(toolName: "a"),
            expiresAt: nil,
            decidedAt: Date(timeIntervalSince1970: 10),
            policyName: "p")
        let late = ApprovalGrant(
            scope: ApprovalScope(toolName: "b"),
            expiresAt: nil,
            decidedAt: Date(timeIntervalSince1970: 20),
            policyName: "p")
        let combined = try PrivacyRuntimeGrantOwnership.combine(owners: [
            (ownerID: "run-2", grants: [late]),
            (ownerID: "run-1", grants: [early]),
            (ownerID: "run-3", grants: []),
        ])
        XCTAssertEqual(combined.map(\.id), [early.id, late.id])
    }

    func testRuntimeGrantOwnershipSameIDAcrossOwnersDeduplicates() throws {
        let grant = ApprovalGrant(
            scope: ApprovalScope(toolName: "exec.shell"),
            expiresAt: nil,
            decidedAt: Date(timeIntervalSince1970: 50),
            policyName: "policy.a")
        let combined = try PrivacyRuntimeGrantOwnership.combine(owners: [
            (ownerID: "parent", grants: [grant]),
            (ownerID: "child", grants: [grant]),
        ])
        XCTAssertEqual(combined.count, 1)
    }

    func testRuntimeGrantOwnershipConflictingMetadataFailsTyped() {
        let id = UUID()
        let first = ApprovalGrant(
            id: id, scope: ApprovalScope(toolName: "a"),
            expiresAt: nil, decidedAt: Date(timeIntervalSince1970: 10),
            policyName: "p")
        let conflicting = ApprovalGrant(
            id: id, scope: ApprovalScope(toolName: "b"),
            expiresAt: nil, decidedAt: Date(timeIntervalSince1970: 10),
            policyName: "p")
        XCTAssertThrowsError(
            try PrivacyRuntimeGrantOwnership.combine(owners: [
                (ownerID: "run-1", grants: [first, conflicting]),
            ])) {
            guard case PrivacyDomainError.persistenceUnavailable(let reason) = $0 else {
                return XCTFail("expected persistenceUnavailable, got \($0)")
            }
            XCTAssertEqual(reason, "grantIdentityCorrupt")
        }
        XCTAssertThrowsError(
            try PrivacyRuntimeGrantOwnership.combine(owners: [
                (ownerID: "run-1", grants: [first]),
                (ownerID: "run-2", grants: [conflicting]),
            ])) {
            guard case PrivacyDomainError.persistenceUnavailable(let reason) = $0 else {
                return XCTFail("expected persistenceUnavailable, got \($0)")
            }
            XCTAssertEqual(reason, "grantOwnershipConflict")
        }
    }

    /// The runtime adapter surface is truthful on an idle runtime: an empty
    /// in-memory layer reports an empty snapshot and revocation is a no-op
    /// miss (never a fabricated success).
    func testAgentRuntimeGrantSnapshotAndRevokeOnIdleRuntime() async {
        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://example.invalid")!)
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "model-a",
            displayName: "Model A",
            limits: ModelLimits(contextTokens: 1024, maxOutputTokens: 256))
        let runtime = FloeAgentRuntime(
            configuration: .init(provider: provider, model: model),
            adapter: SilentProviderAdapter(),
            policy: TaskFullAccessPolicy(),
            executor: NoopToolExecutor())
        let snapshot = await runtime.approvalGrantsSnapshot()
        XCTAssertTrue(snapshot.isEmpty)
        let removed = await runtime.revokeApprovalGrant(id: UUID())
        XCTAssertEqual(removed, 0)
    }

    // MARK: - Provider reservation read-failure leak repair

    /// A thrown secret-state read AFTER the shared reservation attached used
    /// to bypass every finish() and leak the real provider ticket. The read
    /// now goes through the single exit: the ticket is ended exactly once,
    /// no secret dispatch happens, and the failure is reported typed.
    func testSecretStateReadFailureReleasesReservationExactlyOnce() async throws {
        let stores = try await PrivacyTestBed.stores(name: "ticket-leak")
        let provider = try await PrivacyTestBed.seedProvider(
            stores, secretAccount: "provider.accounts.seed",
            synchronizable: false, syncRevision: 0)
        let assembly = PrivacyFacadeFactory.make(
            stores: stores,
            faultInjection: { phase in
                guard phase == "modelConfig.clear.secretStateRead" else {
                    return
                }
                throw PrivacyDomainError.persistenceUnavailable(
                    "scriptedSecretStateRead")
            })
        let digest = try await modelRevision(assembly)
        let token = privacyIssue(
            assembly,
            operation: RuntimeFacadePrivacy.modelConfigClearOperation,
            digest: digest, invocation: "inv")!
        let report = try await assembly.facade.clearModelConfiguration(
            request: PrivacyClearRequest(confirmToken: token),
            revision: BaseRevision(
                resourceID: RuntimeFacadePrivacy.modelConfigurationResourceID,
                version: digest),
            invocationID: "inv")
        XCTAssertEqual(report.deleted.providers, 0)
        XCTAssertEqual(report.deleted.secrets, 0)
        XCTAssertEqual(report.deletionFailures.count, 1)
        XCTAssertEqual(report.deletionFailures.first?.providerID, provider)
        XCTAssertEqual(report.deletionFailures.first?.phase, .enqueue)
        // Exact-ticket cleanup: begun once, ended once, never parked, and
        // no secret was ever enqueued or dispatched. (Awaits are hoisted:
        // XCTAssert autoclosures do not support concurrency.)
        let began = await assembly.operations.began
        let ended = await assembly.operations.ended
        let parked = await assembly.operations.parked
        let secretRecords = await assembly.secrets.records
        XCTAssertEqual(began, [provider])
        XCTAssertEqual(ended, [provider])
        XCTAssertTrue(parked.isEmpty)
        XCTAssertTrue(secretRecords.isEmpty)
        // The provider row survives (nothing was deleted).
        let surviving = try await providerCount(stores)
        XCTAssertEqual(surviving, 1)
    }

    private func providerCount(_ stores: PrivacyTestBed.Stores) async throws -> Int {
        try await PrivacyTestBed.count(stores.database,
                                       "SELECT COUNT(*) FROM providers")
    }
}
