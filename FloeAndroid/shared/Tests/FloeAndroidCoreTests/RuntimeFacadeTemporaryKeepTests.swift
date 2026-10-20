// SPDX-License-Identifier: MPL-2.0
//
// RB-5 atomic Keep tests: ONE original promoter transaction over the real
// file-backed schema-46 database, reopen-consistent durable verification,
// keep/end/launch races under the owner-controlled commit fence, truthful
// pre/post-commit failure semantics, idempotent repeats and tail-once
// forwarding. AUTHORED, NOT EXECUTED — nothing here ran.
import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloeTools
import FloePersistence
@testable import FloeAndroidCore

final class RuntimeFacadeTemporaryKeepTests: XCTestCase {
    private var fixture: TemporaryDomainFixture!

    override func setUp() async throws {
        fixture = try await TemporaryDomainFixture.make()
    }

    override func tearDown() async throws {
        await fixture.teardown()
    }

    private func keep(_ cid: UUID, _ inc: UUID, receipt: String? = nil,
                      correlation: String = "k") async -> TemporaryDomainReply {
        await fixture.domain.keep(conversationID: cid, incarnation: inc,
                                  idempotencyKey: UUID(), receipt: receipt,
                                  correlation: correlation)
    }

    private func ended(_ cid: UUID, _ inc: UUID) async -> TemporaryDomainReply {
        await fixture.domain.end(conversationID: cid, incarnation: inc)
    }

    // MARK: - Atomic single-transaction Keep + reopen consistency

    func testKeepCommitsOneTransactionAndReopensFullyConsistent() async throws {
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        let run = try await fixture.seedTurn(conversationID: cid, canary: "KEEP")
        // Nothing durable BEFORE the Keep.
        var counts = try await fixture.durableCounts()
        XCTAssertEqual(counts["conversations"], 0)
        XCTAssertEqual(counts["message_fts"], 0)

        let reply = await keep(cid, inc)
        guard case .mutationAccepted(let detail, _) = reply.outcome else {
            return XCTFail("keep must accept: \(reply.outcome)")
        }
        XCTAssertEqual(detail["keep"], "committed")
        XCTAssertEqual(detail["conversationID"], cid.uuidString)
        XCTAssertEqual(detail["temporaryAtStart"], "true")
        XCTAssertEqual(detail["frozenTemporaryRun"], "true")

        // Reopen through fresh store objects over the same file: every
        // participating row must be present, owned and coherent.
        let reopened = try await fixture.durableConversations
            .conversation(id: cid)
        XCTAssertNotNil(reopened)
        XCTAssertEqual(reopened?.purpose, .ordinary)       // durable projection
        XCTAssertNotNil(reopened?.title, "")               // promoted fallback
        let messages = try await fixture.durableConversations
            .messages(conversationID: cid)
        XCTAssertEqual(messages.count, 2)
        let parts0 = try await fixture.durableConversations.parts(messageID: messages[0].id)
        XCTAssertEqual(parts0.count, 1)
        let runs = try await fixture.durableRuns.runs(conversationID: cid)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.id, run)
        let events = try await fixture.durableRuns.events(runID: run)
        // The frozen run header + two buffered events committed; sequences
        // strictly increasing from 1 (original per-run counter semantics).
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.sequence), [1, 2])
        let usage = try await fixture.durableRuns.usage(runID: run)
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage.first?.inputTokens, 7)
        let errors = try await fixture.durableRuns.errors(runID: run)
        XCTAssertEqual(errors.count, 1)
        let inputs = try await fixture.durableInputs.pending(conversationID: cid)
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs.first?.status, .queued)      // once-only freeze
        // Ownership: workspace + ownership row created INSIDE the SAME
        // transaction by the original promoter route (explicit canonical
        // private-task workspace — never a silent first-workspace pick).
        counts = try await fixture.durableCounts()
        XCTAssertEqual(counts["workspaces"], 1)
        XCTAssertEqual(counts["conversation_workspace_ownership"], 1)
        XCTAssertEqual(counts["messages"], 2)
        XCTAssertEqual(counts["message_parts"], 2)
        XCTAssertEqual(counts["run_events"], 2)
        // FTS rode the schema's own triggers (searchable history).
        let fts = try await fixture.census.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message_fts") ?? -1
        }
        XCTAssertGreaterThan(fts, 0)
        // The RAM session detached; promoted identity is the durable truth.
        let status = await fixture.domain.status()
        XCTAssertFalse(status.active)
    }

    func testDurableReferencesCarryOriginalSchemaOwnership() async throws {
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        _ = try await fixture.seedTurn(conversationID: cid, canary: "OWN")
        _ = await keep(cid, inc)
        // provider_id/model_id on the durable run reference the REAL
        // snapshot ids (never dummies); the row validates under the
        // original FK graph (conversation ← run ← events/usage/errors).
        let runRow: (provider: String?, model: String?) =
            try await fixture.census.reader { db in
                let row = try Row.fetchOne(db, sql: "SELECT provider_id, model_id FROM runs LIMIT 1")
                return (row?["provider_id"], row?["model_id"])
            }
        XCTAssertNotNil(runRow.provider)
        XCTAssertNotNil(runRow.model)
        let conversationPurpose = try await fixture.census.reader { db in
            try String.fetchOne(db, sql: "SELECT purpose FROM conversations LIMIT 1")
        }
        XCTAssertEqual(conversationPurpose, "ordinary")
    }

    // MARK: - Idempotency / duplicates

    func testRepeatedKeepAfterCommittedReceiptPerformsNoSecondDBWork() async throws {
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        _ = try await fixture.seedTurn(conversationID: cid, canary: "DUP")
        _ = await keep(cid, inc)
        let before = try await fixture.durableCounts()
        // Same hosted id + incarnation, no active session (the committed
        // Keep detached it): the receipt is surfaced again with zero new
        // durable effects.
        let again = await keep(cid, inc, correlation: "k2")
        guard case .mutationAccepted(let detail, _) = again.outcome else {
            return XCTFail("repeat keep must surface the receipt: \(again.outcome)")
        }
        XCTAssertEqual(detail["keep"], "alreadyCommitted")
        let afterCounts = try await fixture.durableCounts()
        XCTAssertEqual(before, afterCounts)
        // A stale expectation for a DIFFERENT conversation can never adopt
        // the promoted receipt.
        let foreign = await keep(UUID(), inc, correlation: "k3")
        guard case .rejected = foreign.outcome else {
            return XCTFail("foreign repeat keep must refuse")
        }
        let afterForeignCounts = try await fixture.durableCounts()
        XCTAssertEqual(afterForeignCounts, before)
    }

    func testConcurrentSecondKeepWhileInFlightRefusedWithoutSecondWriter() async throws {
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        _ = try await fixture.seedTurn(conversationID: cid, canary: "RACE")
        let gate = TempGateBox()
        await fixture.domain.setTestHooksForTesting(afterFreezeBeforeCommit: {
            await gate.wait()
        })
        let domainRef = fixture.domain
        let first = Task { await domainRef.keep(conversationID: cid,
            incarnation: inc, idempotencyKey: UUID(), receipt: nil,
            correlation: "inflight-1") }
        // Wait until the first attempt is stalled at the frozen snapshot
        // (promotion marker committed to the slot).
        for _ in 0..<500 {
            let status = await fixture.domain.status()
            if status.promotion == "inFlight" { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let second = await keep(cid, inc, correlation: "inflight-2")
        guard case .rejected(let error) = second.outcome else {
            return XCTFail("second writer must be refused")
        }
        XCTAssertEqual(error.code, TemporaryDomainError.Code.duplicateInFlight)
        gate.release()
        _ = await first.value
        let counts = try await fixture.durableCounts()
        XCTAssertEqual(counts["messages"], 2)   // exactly one promotion
    }

    // MARK: - Races: navigation across a blocked commit (commit fence)

    func testNavigationAcrossBlockedCommitPersistsNothingAndNeverResurrects() async throws {
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        _ = try await fixture.seedTurn(conversationID: cid, canary: "FENCED")
        let gate = TempGateBox()
        await fixture.domain.setTestHooksForTesting(afterFreezeBeforeCommit: {
            await gate.wait()   // Keep is frozen at the watermark; the
                                // promoter transaction is still blocked.
        })
        let domainRef = fixture.domain
        let keepTask = Task { await domainRef.keep(conversationID: cid,
            incarnation: inc, idempotencyKey: UUID(), receipt: nil,
            correlation: "fence") }
        for _ in 0..<500 {
            let status = await fixture.domain.status()
            if status.promotion == "inFlight" { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        // ACTUAL navigation lands while the commit is blocked.
        let endReply = await ended(cid, inc)
        guard case .mutationAccepted = endReply.outcome else {
            return XCTFail("navigation end must accept")
        }
        gate.release()
        // The promoter's EARLY inside-transaction fence check refuses the
        // whole transaction: discarded content NEVER persists.
        let keepReply = await keepTask.value
        guard case .rejected(let error) = keepReply.outcome else {
            return XCTFail("fence must refuse the blocked commit: \(keepReply.outcome)")
        }
        XCTAssertEqual(error.code, TemporaryDomainError.Code.sessionDiscarded)
        XCTAssertEqual(error.reason, TemporaryDomainError.Reason.promotionRefusedByFence)
        let counts = try await fixture.durableCounts()
        XCTAssertEqual(counts["conversations"], 0)
        XCTAssertEqual(counts["messages"], 0)
        XCTAssertEqual(counts["run_events"], 0)
        XCTAssertEqual(counts["message_fts"], 0)
        XCTAssertEqual(counts["workspaces"], 0)
        // The tombstoned session never resurrects: retries stay refused.
        let retry = await keep(cid, inc, correlation: "fence-retry")
        guard case .rejected = retry.outcome else {
            return XCTFail("tombstoned session must not resurrect")
        }
        let afterRetryCounts = try await fixture.durableCounts()
        XCTAssertEqual(afterRetryCounts, counts)
    }

    func testCommitThatTrulyCompletedBeforeTheFlipStaysOrdinaryTruth() async throws {
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        _ = try await fixture.seedTurn(conversationID: cid, canary: "WON")
        // The Keep completes fully; ONLY THEN does navigation land.
        _ = await keep(cid, inc)
        _ = await ended(cid, inc)
        let counts = try await fixture.durableCounts()
        XCTAssertEqual(counts["conversations"], 1)   // committed = ordinary truth
        XCTAssertEqual(counts["messages"], 2)
    }

    // MARK: - Pre-commit failure: rollback to zero, RAM intact, retryable

    func testPreCommitConflictRollsBackToZeroAndKeepsRAMRetryable() async throws {
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        let run = try await fixture.seedTurn(conversationID: cid, canary: "ROLL")
        // Plant a genuine cross-owner conflict the ORIGINAL validator
        // proves: one snapshot message id already durable under ANOTHER
        // ordinary conversation. (No runID on the planted row: its
        // snapshot twin's FK target is only durable AFTER the promoted
        // commit — the conflict proof is at the message-owner level,
        // exactly what `rejectForeignRows` checks.)
        let otherID = UUID()
        try await fixture.durableConversations.saveConversation(
            ConversationRecord(id: otherID, title: "other",
                               createdAt: Date(), updatedAt: Date()))
        let durableUnderHosted = try await fixture.durableConversations
            .messages(conversationID: cid)   // the hosted id has NO durable rows
        XCTAssertEqual(durableUnderHosted.count, 0)
        // Read the snapshot's first message id through the RAM stores.
        let authority = await fixture.domain.authority(conversationID: cid,
                                                       incarnation: inc)!
        let ramMessages = try await authority.stores.conversations
            .messages(conversationID: cid)
        try await fixture.durableConversations.appendMessage(
            PersistedMessage(id: ramMessages[0].id, conversationID: otherID,
                             role: "user", content: "foreign",
                             createdAt: Date()))
        _ = run
        let reply = await keep(cid, inc)
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("conflicting keep must be refused")
        }
        XCTAssertEqual(error.code, TemporaryDomainError.Code.persistenceUnavailable)
        // ZERO durable rows of the snapshot (the planted foreign row is
        // not the promoted conversation).
        let counts = try await fixture.durableCounts()
        XCTAssertEqual(counts["conversations"], 1)   // only the planted other
        XCTAssertEqual(counts["messages"], 1)
        XCTAssertEqual(counts["run_events"], 0)
        // The planted row wrote no workspace: workspace creation happens
        // ONLY inside a committed promotion.
        XCTAssertEqual(counts["workspaces"], 0)
        // The live RAM session is INTACT and retryable (abort restored
        // `.idle`, nothing forwarded).
        let status = await fixture.domain.status()
        XCTAssertTrue(status.active)
        XCTAssertEqual(status.promotion, "idle")
        // Remove the conflict and retry successfully (original stores
        // never lost the buffered content).
        try await fixture.census.writer { db in
            try db.execute(sql: "DELETE FROM messages")
            try db.execute(sql: "DELETE FROM conversations WHERE id = ?",
                           arguments: [otherID.uuidString])
        }
        let retry = await keep(cid, inc, correlation: "retry")
        guard case .mutationAccepted = retry.outcome else {
            return XCTFail("retry must commit: \(retry.outcome)")
        }
    }

    // MARK: - Post-commit tail failure: truthful resume-once

    func testTailFailureAfterCommitReportsDurableTruthAndResumesOnceWithoutDuplicates() async throws {
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        _ = try await fixture.seedTurn(conversationID: cid, canary: "TAIL")
        // Fail the FIRST gateway step after the commit succeeded.
        await fixture.domain.setTestHooksForTesting(beforeGatewayStep: { step in
            if step == 1 {
                throw FloeError.internalError("staged gateway failure")
            }
        })
        let reply = await keep(cid, inc)
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("tail step failure must be reported: \(reply.outcome)")
        }
        XCTAssertEqual(error.code, TemporaryDomainError.Code.persistenceUnavailable)
        XCTAssertEqual(error.reason, TemporaryDomainError.Reason.tailForwardPending)
        // TRUTHFUL: the core transaction committed — the conversation IS
        // ordinary durable now (no false "nothing saved").
        var counts = try await fixture.durableCounts()
        XCTAssertEqual(counts["conversations"], 1)
        XCTAssertEqual(counts["messages"], 2)
        let status = await fixture.domain.status()
        XCTAssertTrue(status.active)                      // retryable same session
        XCTAssertEqual(status.promotion, "tailPending")
        // Clear the failure and retry ONCE: the frozen context resumes the
        // failed step (no re-begin, no double insert).
        await fixture.domain.setTestHooksForTesting(beforeGatewayStep: nil)
        let retry = await keep(cid, inc, correlation: "tail-retry")
        guard case .mutationAccepted(let detail, _) = retry.outcome else {
            return XCTFail("resume must accept: \(retry.outcome)")
        }
        XCTAssertEqual(detail["keep"], "committed")
        counts = try await fixture.durableCounts()
        XCTAssertEqual(counts["messages"], 2)             // exactly once
        XCTAssertEqual(counts["run_events"], 2)
        XCTAssertEqual(counts["pending_user_inputs"], 1)
    }

    func testTailWritesDuringFreezeAndCommitAreForwardedOnceInOrder() async throws {
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        let run = try await fixture.seedTurn(conversationID: cid, canary: "TWO")
        let authority = await fixture.domain.authority(conversationID: cid,
                                                       incarnation: inc)!
        // Start the Keep and stall AFTER commit, BEFORE the gateway tail
        // steps — meanwhile the live run appends tail rows (buffered in
        // RAM by the promoting gate).
        let gate = TempGateBox()
        await fixture.domain.setTestHooksForTesting(afterCommit: {
            await gate.wait()
        })
        let domainRef = fixture.domain
        let keepTask = Task { await domainRef.keep(conversationID: cid,
            incarnation: inc, idempotencyKey: UUID(), receipt: nil,
            correlation: "tail-live") }
        for _ in 0..<500 {
            let status = await fixture.domain.status()
            if status.promotion == "inFlight" { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        _ = try await authority.stores.runs.appendEvent(
            runID: run, kind: .assistantText,
            payloadJSON: "{\"delta\":\"tail\"}")
        gate.release()
        _ = await keepTask.value
        let events = try await fixture.durableRuns.events(runID: run)
        // Watermark events committed inside the transaction; the tail
        // forwarded EXACTLY once, in original order, with durable-minted
        // identities continuing the sequence.
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(events.last?.payloadJSON, "{\"delta\":\"tail\"}")
        let counts = try await fixture.durableCounts()
        XCTAssertEqual(counts["run_events"], 3)
    }

    func testHostCancelBeforeCommitEqualsFenceRefusal() async throws {
        // The host's cancel-before-commit IS a navigation end landing
        // while the commit is blocked — identical fence semantics, proven
        // with the mailbox job ordering.
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        _ = try await fixture.seedTurn(conversationID: cid, canary: "H-cancel")
        let gate = TempGateBox()
        await fixture.domain.setTestHooksForTesting(afterFreezeBeforeCommit: {
            await gate.wait()
        })
        let domainRef = fixture.domain
        let keepTask = Task { await domainRef.keep(conversationID: cid,
            incarnation: inc, idempotencyKey: UUID(), receipt: nil,
            correlation: "h") }
        for _ in 0..<500 {
            let status = await fixture.domain.status()
            if status.promotion == "inFlight" { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        _ = await ended(cid, inc)
        gate.release()
        let reply = await keepTask.value
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("fence must refuse")
        }
        XCTAssertEqual(error.reason, TemporaryDomainError.Reason.promotionRefusedByFence)
        let counts = try await fixture.durableCounts()
        XCTAssertEqual(counts["conversations"], 0)
    }

    // MARK: - Wrong identity / foreign routes

    func testKeepWrongIncarnationAndForeignRouteRefuseBeforeAnyStoreTouch() async throws {
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        _ = try await fixture.seedTurn(conversationID: cid, canary: "WRONG")
        let wrongInc = await keep(cid, UUID())
        guard case .rejected(let e1) = wrongInc.outcome else { return XCTFail("1") }
        XCTAssertEqual(e1.code, TemporaryDomainError.Code.staleRevision)
        let foreign = await keep(UUID(), inc)
        guard case .rejected(let e2) = foreign.outcome else { return XCTFail("2") }
        XCTAssertEqual(e2.reason, TemporaryDomainError.Reason.sessionNotCurrent)
        // Nothing promoted, nothing touched, session intact.
        let counts = try await fixture.durableCounts()
        XCTAssertEqual(counts["conversations"], 0)
        let activeNow = await fixture.domain.status().active
        XCTAssertTrue(activeNow)
    }

    func testRevisionSpellingIsEnforcedByTheWiredIdentityProof() throws {
        // The processor identity extractor binds resourceID to the taskID:
        // any other spelling is a pre-effect refusal.
        let cid = UUID()
        let inc = UUID()
        var envelope = TemporaryTestEnvelopes.tempKeep(conversationID: cid,
                                                      incarnation: inc)
        envelope["revision"] = ["resourceID": "session.\(UUID().uuidString)",
                                "version": inc.uuidString]
        XCTAssertNil(TemporaryDomainFacade.hostedIdentity(from: envelope))
        envelope["revision"] = ["resourceID": "session.\(cid.uuidString)",
                                "version": "not-a-uuid"]
        XCTAssertNil(TemporaryDomainFacade.hostedIdentity(from: envelope))
        var end = TemporaryTestEnvelopes.tempEnd(conversationID: cid,
                                                 incarnation: inc)
        end["owner"] = ["taskID": cid.uuidString, "runID": UUID().uuidString]
        // Grammar-level run-role smuggling: resourceID still must bind; the
        // v3 validator rejects this envelope shape upstream (frozen rule),
        // and the identity proof here is consistent.
        let identity = TemporaryDomainFacade.hostedIdentity(from: end)
        XCTAssertNotNil(identity)  // extra owner roles are refused EARLIER
                                   // by the frozen grammar, not by RB5.
    }

    // MARK: - No raw content in failure diagnostics

    func testKeepFailureDetailsCarryOnlyClosedTypedVocabulary() async throws {
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        _ = try await fixture.seedTurn(conversationID: cid, canary: "CANARY-SECRET-TEXT")
        await fixture.domain.setTestHooksForTesting(beforeGatewayStep: { _ in
            throw FloeError.internalError("internal detail that must NOT leak")
        })
        let reply = await keep(cid, inc)
        guard case .rejected(let error) = reply.outcome else { return XCTFail("must fail") }
        let result = reply.commandResult()
        let detail = result.detail ?? [:]
        XCTAssertEqual(Set(detail.keys), ["error", "reason"])
        XCTAssertEqual(detail["error"], error.code.rawValue)
        XCTAssertEqual(detail["reason"], error.reason.rawValue)
        let serialized = try JSONSerialization.data(
            withJSONObject: detail).description
        XCTAssertFalse(serialized.contains("CANARY-SECRET-TEXT"))
        XCTAssertFalse(serialized.contains("internal detail"))
    }

    // MARK: - Route ownership promoted exactly once; late callbacks inert

    func testCommittedKeepPromotesRouteOwnershipOnceAndLateCallbacksCannotTargetNewSessions() async throws {
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        _ = try await fixture.seedTurn(conversationID: cid, canary: "ROUTE")
        _ = await keep(cid, inc)
        XCTAssertEqual(fixture.surface.promoted.count, 1)
        XCTAssertEqual(fixture.surface.promoted.first?.durableConversationID, cid)
        // Start a fresh session (new hosted id + incarnation): the old
        // session's promoted route must not migrate anything to it, and a
        // late surface/authority callback for the old incarnation resolves
        // to nothing.
        let second = try await fixture.startedSession()
        let authA = await fixture.domain.authority(conversationID: cid, incarnation: inc)
        XCTAssertNil(authA)
        let authB = await fixture.domain.authority(
            conversationID: second.conversationID,
            incarnation: second.incarnation)
        XCTAssertNotNil(authB)
        XCTAssertEqual(fixture.surface.promoted.count, 1)   // still exactly one
    }

    // MARK: - Generation retirement: discard, never auto-Keep

    func testGenerationRetirementDiscardsWithoutAnyDurableWrite() async throws {
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        _ = try await fixture.seedTurn(conversationID: cid, canary: "SHUTDOWN")
        // A live run at shutdown: explicit cancel dispatched, not awaited
        // forever (no timeout detach anywhere).
        _ = await fixture.domain.temporaryLaunch(
            conversationID: cid, incarnation: inc,
            correlation: "live", receipt: nil, goal: "g", mode: "chat",
            preferredModelID: nil, attachmentCount: 0,
            stagedAttachmentHandles: 0)
        await TemporaryDomainFacade.beginGenerationRetirement(epoch: fixture.epoch)
        let status = await fixture.domain.status()
        XCTAssertFalse(status.active)
        XCTAssertEqual(fixture.port.recordedCancels.count, 1)
        let counts = try await fixture.durableCounts()
        XCTAssertEqual(counts["conversations"], 0)
        XCTAssertEqual(counts["messages"], 0)
        XCTAssertEqual(counts["run_events"], 0)
        // A late Keep on the retired identity is refused (no resurrection,
        // no auto-keep).
        let late = await keep(cid, inc)
        guard case .rejected = late.outcome else { return XCTFail("late keep") }
    }
}
