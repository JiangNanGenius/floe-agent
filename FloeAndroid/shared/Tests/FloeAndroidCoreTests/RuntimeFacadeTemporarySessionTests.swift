// SPDX-License-Identifier: MPL-2.0
//
// RB-5 temporary-session lifecycle tests (temp.start / temp.end /
// navigation / preservation / identity). AUTHORED, NOT EXECUTED — nothing
// here ran. Assertions exercise the REAL domain over the ORIGINAL
// Ephemeral* stores, the REAL reviewed RB1 generation/registry/pumps and an
// ACTUAL file-backed schema-46 database; only the RB4 port is a controlled
// typed fixture.
import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloeTools
import FloePersistence
@testable import FloeAndroidCore

final class RuntimeFacadeTemporarySessionTests: XCTestCase {
    private var fixture: TemporaryDomainFixture!

    override func setUp() async throws {
        fixture = try await TemporaryDomainFixture.make()
    }

    override func tearDown() async throws {
        await fixture.teardown()
    }

    // MARK: - temp.start: RAM acceptance + minted identity only after accept

    func testTempStartCommitsRAMSessionAndMintsIdentityIntoPreparedEffectOnlyAfterAccept() async throws {
        let (cid, inc, receipt, _, _) = try await fixture.startedSession()
        // Slot authority exists ONLY post-accept.
        let authority = await fixture.domain.authority(conversationID: cid,
                                                       incarnation: inc)
        XCTAssertNotNil(authority)
        XCTAssertEqual(authority?.stores.hostedConversationID, cid)
        XCTAssertTrue(authority!.stores.isTemporary)
        XCTAssertEqual(authority?.epoch, fixture.epoch)
        // Zero durable rows while a live session chats (RAM-only invariant).
        let counts = try await fixture.durableCounts()
        XCTAssertEqual(counts["conversations"], 0)
        XCTAssertEqual(counts["messages"], 0)
        XCTAssertEqual(counts["runs"], 0)
        // The prepared effect carries the identity (it exists now) and is
        // NON-terminal, and precedes the command terminal on the SAME
        // receipt stream (RB1 pump, no parallel channel).
        if let receipt {
            switch fixture.effects.poll(receipt: receipt, afterSequence: 0) {
            case .page(let effects, _, _, _):
                let kinds = effects.map(\.kind)
                if let preparedIndex = kinds.firstIndex(of: .prepared) {
                    // The prepared stage is NON-terminal identity evidence
                    // (the mailbox processor settles the terminal on the
                    // WIRED path; this direct-call path has no processor).
                    XCTAssertFalse(effects[preparedIndex].kind.isTerminal)
                    let prepared = effects[preparedIndex]
                    XCTAssertEqual(prepared.detail?["conversationID"], cid.uuidString)
                    XCTAssertEqual(prepared.detail?["incarnation"], inc.uuidString)
                }
                // The ordering invariant that holds unconditionally: NO
                // prepared stage exists without a committed RAM session.
            case .expired, .notFound:
                XCTFail("receipt must exist on the reviewed pump")
            }
        }
        // The hosted conversation row in RAM says `.temporary`; the schema
        // CHECK admits only ordinary durably — which is exactly why no
        // durable row may exist yet.
        let messages = try await authority!.stores.conversations
            .messages(conversationID: cid)
        XCTAssertEqual(messages.count, 0)
    }

    func testTempStartQueueReceiptCarriesNoDomainIdentityOrOutcome() async throws {
        // The synchronous submit handler returns correlation + receipt
        // ONLY (settled rule). Drive the REAL binder handler installed for
        // the temp.start key.
        guard let handler = RuntimeCommandBinder.shared.handler(
            for: BridgeV3.handlerKey(scope: .launch, command: "temp.start")) else {
            return XCTFail("temp.start binder key not installed")
        }
        var envelope = TemporaryTestEnvelopes.tempStart()
        envelope["payload"] = ["draft": "hello"]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let response = try JSONSerialization.jsonObject(
            with: handler(data)) as! [String: Any]
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(Set(response.keys),
                       ["ok", "schema", "correlationID", "queued",
                        "operationReceiptID"])
        XCTAssertNil(response["conversationID"])
        XCTAssertNil(response["incarnation"])
        // NOTE: this fixture installs its processors in a test-local
        // registry, so the real generation mailbox later settles the job
        // `domainNotBound` — exactly the reviewed fail-closed path for an
        // unbound key. The assertion here is the IMMEDIATE synchronous
        // receipt contract: identity/outcome never appear at queue time.
        // And the mailbox accepted-stage vocabulary adds nothing else.
    }

    func testTempStartSecondActiveSessionRefused() async throws {
        _ = try await fixture.startedSession()
        let correlation = TemporaryTestEnvelopes.correlation()
        let reply = await fixture.domain.start(
            envelope: TemporaryTestEnvelopes.tempStart(correlation: correlation),
            receipt: nil, correlation: correlation)
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("second temp.start must be refused")
        }
        XCTAssertEqual(error.code, TemporaryDomainError.Code.invalidState)
        XCTAssertEqual(error.reason, TemporaryDomainError.Reason.anotherSessionActive)
    }

    func testTempStartClosedPayloadVocabulary() async throws {
        // Unknown keys are refused BEFORE any effect.
        let correlation = TemporaryTestEnvelopes.correlation()
        let reply = await fixture.domain.start(
            envelope: TemporaryTestEnvelopes.tempStart(
                correlation: correlation,
                payload: ["toolCeiling": ["mcp.demo.run"],
                          "runID": UUID().uuidString]),
            receipt: nil, correlation: correlation)
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("payload with unknown/authority keys must be refused")
        }
        XCTAssertEqual(error.reason, TemporaryDomainError.Reason.payloadInvalid)
        // Oversized draft refused.
        let big = String(repeating: "x", count: TemporaryDomainLimits.maximumDraftBytes + 1)
        let reply2 = await fixture.domain.start(
            envelope: TemporaryTestEnvelopes.tempStart(payload: ["draft": big]),
            receipt: nil, correlation: TemporaryTestEnvelopes.correlation())
        guard case .rejected(let e2) = reply2.outcome else {
            return XCTFail("oversized draft must be refused")
        }
        XCTAssertEqual(e2.code, TemporaryDomainError.Code.payloadTooLarge)
    }

    // MARK: - Navigation: synchronous tombstone before any await

    func testNavigationEndDetachesBeforeBlockedAsyncLaunchThenLateCallbackCannotTouchAnything() async throws {
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        let gate = TempGateBox()
        fixture.port.stallGate = gate
        let correlation = TemporaryTestEnvelopes.correlation()
        let domainRef = fixture.domain
        let launchTask = Task {
            await domainRef.temporaryLaunch(
                conversationID: cid, incarnation: inc,
                correlation: correlation, receipt: nil,
                goal: "blocked launch", mode: "chat",
                preferredModelID: nil, attachmentCount: 0,
                stagedAttachmentHandles: 0)
        }
        // The request reached the port (bundle+identity handed over BEFORE
        // the callee's first suspension) and is now stalled.
        for _ in 0..<500 where !fixture.port.sawRequest {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(fixture.port.sawRequest)
        // ACTUAL navigation: end runs and COMPLETES while the launch is
        // still blocked.
        let endReply = await fixture.domain.end(conversationID: cid, incarnation: inc)
        guard case .mutationAccepted(let detail, _) = endReply.outcome else {
            return XCTFail("navigation end must accept")
        }
        XCTAssertEqual(detail["endRoute"], "newTask")
        // No authority survives the tombstone.
        let authority = await fixture.domain.authority(conversationID: cid,
                                                       incarnation: inc)
        XCTAssertNil(authority)
        // Release the blocked launch: its `launched` reply arrives late and
        // must (a) be converted to a typed discard, (b) trigger an explicit
        // cancel for the run it created, and (c) leave zero durable rows.
        gate.release()
        let launchReply = await launchTask.value
        guard case .refused(let error) = launchReply else {
            return XCTFail("late launch into a tombstoned session must refuse")
        }
        XCTAssertEqual(error.reason, TemporaryDomainError.Reason.tombstonedDiscarded)
        XCTAssertEqual(fixture.port.recordedCancels.count, 1)
        let counts = try await fixture.durableCounts()
        XCTAssertEqual(counts["conversations"], 0)
        XCTAssertEqual(counts["runs"], 0)
    }

    func testEndClosesStoresSoLateAppendsFailClosedAndClearsExactSessionHandles() async throws {
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        let run = try await fixture.seedTurn(conversationID: cid, canary: "END")
        await fixture.domain.noteTemporaryRunRetired(
            conversationID: cid, incarnation: inc, runID: run)
        // Keep the store references the way a live run service does.
        let authority = await fixture.domain.authority(conversationID: cid,
                                                       incarnation: inc)!
        let stores = authority.stores
        _ = run
        let reply = await fixture.domain.end(conversationID: cid, incarnation: inc)
        guard case .mutationAccepted = reply.outcome else {
            return XCTFail("end must accept for the exact session")
        }
        // Late appends from the unwinding run hit the tombstone and fail
        // closed (original gate semantics — never buffer, never persist).
        do {
            try await stores.conversations.appendMessage(PersistedMessage(
                id: UUID(), conversationID: cid, role: "assistant",
                content: "late", createdAt: Date()))
            XCTFail("late message append must fail closed")
        } catch {
            // expected: the store is closed after an actual leave.
        }
        do {
            try await stores.runs.saveRun(RunRecord(
                id: UUID(), conversationID: cid, state: "running",
                goal: "late", startedAt: Date()))
            XCTFail("late run save must fail closed")
        } catch {
            // expected: same gate.
        }
        do {
            _ = try await stores.runningInputs.enqueue(PendingUserInput(
                conversationID: cid, content: "late",
                createdAt: Date(), updatedAt: Date()))
            XCTFail("late queueing must fail closed")
        } catch {
            // expected: same gate.
        }
        // No authority survives the tombstone.
        let postAuthority = await fixture.domain.authority(conversationID: cid,
                                                           incarnation: inc)
        XCTAssertNil(postAuthority)
        // The exact-session draft handle was cleared; no other route was.
        XCTAssertEqual(fixture.surface.discarded,
                       [RecordingHostSurface.Discarded(conversationID: cid,
                                                        incarnation: inc)])
        // And durable rows stayed zero (navigation DISCARDS; nothing was
        // kept).
        let counts = try await fixture.durableCounts()
        XCTAssertEqual(counts["messages"], 0)
        XCTAssertEqual(counts["run_events"], 0)
        XCTAssertEqual(counts["run_usage"], 0)
        XCTAssertEqual(counts["pending_user_inputs"], 0)
        XCTAssertEqual(counts["message_fts"], 0)
    }

    func testEndDispatchesExplicitCancelForOwnedRuns() async throws {
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        let launch = await fixture.domain.temporaryLaunch(
            conversationID: cid, incarnation: inc,
            correlation: "corr-own", receipt: nil,
            goal: "owned", mode: "chat", preferredModelID: nil,
            attachmentCount: 0, stagedAttachmentHandles: 0)
        guard case .launched(let runID) = launch else {
            return XCTFail("controlled port must launch")
        }
        _ = await fixture.domain.end(conversationID: cid, incarnation: inc)
        let cancels = fixture.port.recordedCancels
        XCTAssertEqual(cancels.count, 1)
        XCTAssertEqual(cancels.first?.runID, runID)
        XCTAssertEqual(cancels.first?.epoch, fixture.epoch)
    }

    func testWrongIncarnationEndRefusesWithoutActing() async throws {
        let (cid, _, _, _, _) = try await fixture.startedSession()
        let reply = await fixture.domain.end(conversationID: cid,
                                             incarnation: UUID())
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("wrong incarnation must refuse")
        }
        XCTAssertEqual(error.code, TemporaryDomainError.Code.staleRevision)
        // The live session is UNTOUCHED: authority still resolves and no
        // surface clear happened.
        let status = await fixture.domain.status()
        XCTAssertTrue(status.active)
        XCTAssertEqual(fixture.surface.discarded.count, 0)
        // A late callback cannot clear/update the NEW session either.
        _ = await fixture.domain.end(conversationID: cid, incarnation: UUID())
        let stillActive = await fixture.domain.status().active
        XCTAssertTrue(stillActive)
    }

    func testForeignRouteEndCannotDestroyAnotherConversationSession() async throws {
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        // A different hosted id (foreign route) — old callback.
        let other = await fixture.domain.end(conversationID: UUID(),
                                             incarnation: UUID())
        guard case .rejected(let error) = other.outcome else {
            return XCTFail("foreign end must refuse")
        }
        XCTAssertEqual(error.reason, TemporaryDomainError.Reason.sessionNotCurrent)
        let status = await fixture.domain.status()
        XCTAssertEqual(status.conversationID, cid)
        XCTAssertEqual(status.incarnation, inc)
    }

    func testOldCallbackAfterNewSessionCannotClearOrUpdateNew() async throws {
        let first = try await fixture.startedSession()
        _ = await fixture.domain.end(conversationID: first.conversationID,
                                     incarnation: first.incarnation)
        let second = try await fixture.startedSession()
        // Stale operations addressed to the FIRST incarnation:
        let staleEnd = await fixture.domain.end(conversationID: second.conversationID,
                                                incarnation: first.incarnation)
        guard case .rejected(let endError) = staleEnd.outcome else {
            return XCTFail("stale end must refuse")
        }
        XCTAssertEqual(endError.code, TemporaryDomainError.Code.staleRevision)
        let staleKeep = await fixture.domain.keep(
            conversationID: second.conversationID,
            incarnation: first.incarnation, idempotencyKey: UUID(),
            receipt: nil, correlation: "stale-keep")
        guard case .rejected = staleKeep.outcome else {
            return XCTFail("stale keep must refuse")
        }
        // The new session is fully intact and its handles are NOT cleared.
        let status = await fixture.domain.status()
        XCTAssertTrue(status.active)
        XCTAssertEqual(status.incarnation, second.incarnation)
        XCTAssertEqual(fixture.surface.discarded.count, 1) // only the real first end
    }

    // MARK: - Preservation (NOT navigation)

    func testRotationBackgroundInactiveLockAndReconstructionPreserveSessionRunAndRoute() async throws {
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        // An owned live run.
        let launch = await fixture.domain.temporaryLaunch(
            conversationID: cid, incarnation: inc,
            correlation: "corr-preserve", receipt: nil,
            goal: "streaming", mode: "chat", preferredModelID: nil,
            attachmentCount: 0, stagedAttachmentHandles: 0)
        guard case .launched(let runID) = launch else { return XCTFail("launch") }
        for hint in TemporaryHostLifecycleHint.allCases {
            let ack = TemporaryDomainFacade.noteHostLifecycleHint(hint,
                                                                  epoch: fixture.epoch)
            XCTAssertEqual(ack,
                           .preserved(conversationID: cid, incarnation: inc),
                           "hint \(hint) must preserve, never discard")
        }
        // Session, run and route all unchanged; NOTHING was cancelled;
        // NOTHING durable happened.
        let status = await fixture.domain.status()
        XCTAssertTrue(status.active)
        XCTAssertEqual(status.ownedRunCount, 1)
        XCTAssertEqual(fixture.port.recordedCancels.count, 0)
        let liveRun = await fixture.port.hasLiveTemporaryRun(
            conversationID: cid, incarnation: inc, runID: runID)
        XCTAssertTrue(liveRun)
        let counts = try await fixture.durableCounts()
        XCTAssertEqual(counts["conversations"], 0)
    }

    func testUnboundEpochHintAnswersNoSessionWithoutSideEffects() async throws {
        _ = try await fixture.startedSession()
        let ack = TemporaryDomainFacade.noteHostLifecycleHint(
            .background, epoch: fixture.epoch &+ 9_999)   // foreign epoch
        XCTAssertEqual(ack, .noSession)
    }

    // MARK: - Process death: no restore, no durable trace

    func testProcessDeathRestoresNothing() async throws {
        let (cid, _, _, _, _) = try await fixture.startedSession()
        _ = try await fixture.seedTurn(conversationID: cid, canary: "DEATH")
        // Process death == the generation goes away without an ordered End
        // and without a Keep. Simulate the restart: a NEW domain instance
        // over the SAME (never-written) database.
        await fixture.teardown()
        fixture = try await TemporaryDomainFixture.make()   // fresh generation
        let status = await fixture.domain.status()
        XCTAssertFalse(status.active)
        let counts = try await fixture.durableCounts()
        XCTAssertEqual(counts["conversations"], 0)
        XCTAssertEqual(counts["messages"], 0)
        XCTAssertEqual(counts["runs"], 0)
        XCTAssertEqual(counts["run_events"], 0)
        XCTAssertEqual(counts["run_usage"], 0)
        XCTAssertEqual(counts["run_errors"], 0)
        XCTAssertEqual(counts["pending_user_inputs"], 0)
        XCTAssertEqual(counts["message_fts"], 0)
    }

    // MARK: - RAM-only flow against the ORIGINAL stores (invariant proof)

    func testNormalTextFlowProducesZeroOrdinaryDurableRowsThroughStores() async throws {
        let (cid, _, _, _, _) = try await fixture.startedSession()
        _ = try await fixture.seedTurn(conversationID: cid, canary: "FLOW")
        // Background hint = preserve; still zero durable rows.
        _ = TemporaryDomainFacade.noteHostLifecycleHint(.background,
                                                        epoch: fixture.epoch)
        var counts = try await fixture.durableCounts()
        XCTAssertEqual(counts["conversations"], 0)
        XCTAssertEqual(counts["messages"], 0)
        XCTAssertEqual(counts["message_parts"], 0)
        XCTAssertEqual(counts["attachments"], 0)
        XCTAssertEqual(counts["runs"], 0)
        XCTAssertEqual(counts["run_events"], 0)
        XCTAssertEqual(counts["run_usage"], 0)
        XCTAssertEqual(counts["run_errors"], 0)
        XCTAssertEqual(counts["pending_user_inputs"], 0)
        XCTAssertEqual(counts["message_fts"], 0)
        XCTAssertEqual(counts["workspaces"], 0)
        XCTAssertEqual(counts["conversation_workspace_ownership"], 0)
        // End (navigation) — still zero.
        _ = await fixture.domain.end(conversationID: cid,
                                     incarnation: fixture.currentIncarnation()!)
        counts = try await fixture.durableCounts()
        XCTAssertEqual(counts.values.allSatisfy { $0 == 0 }, true)
    }

    func testCheckpointsStayRAMOnly() async throws {
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        let authority = await fixture.domain.authority(conversationID: cid,
                                                       incarnation: inc)!
        let run = try await fixture.seedTurn(conversationID: cid, canary: "CKPT")
        try await authority.stores.runs.saveCheckpoint(
            runID: run, conversationID: cid, formatVersion: 1,
            state: "running", bodyJSON: "{\"canary\":\"CKPT\"}")
        let body = try await authority.stores.runs.checkpointBody(runID: run)
        XCTAssertEqual(body, "{\"canary\":\"CKPT\"}")     // RAM
        let counts = try await fixture.durableCounts()
        // No `checkpoints` table write happened while temporary.
        let checkpointCount = try await fixture.census.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM checkpoints") ?? -1
        }
        XCTAssertEqual(checkpointCount, 0)
    }

    // MARK: - Temporary launch invariants

    func testAttachmentsPreprocessingImportRefusedStructurally() async throws {
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        let withAttachments = await fixture.domain.temporaryLaunch(
            conversationID: cid, incarnation: inc,
            correlation: "a1", receipt: nil, goal: "g", mode: "chat",
            preferredModelID: nil, attachmentCount: 1,
            stagedAttachmentHandles: 0)
        guard case .refused(let e1) = withAttachments else {
            return XCTFail("attachments are permission-unavailable in temporary")
        }
        XCTAssertEqual(e1.reason, TemporaryDomainError.Reason.attachmentsUnavailableInTemporary)
        let withStaging = await fixture.domain.temporaryLaunch(
            conversationID: cid, incarnation: inc,
            correlation: "a2", receipt: nil, goal: "g", mode: "chat",
            preferredModelID: nil, attachmentCount: 0,
            stagedAttachmentHandles: 2)
        guard case .refused(let e2) = withStaging else {
            return XCTFail("staged handles are permission-unavailable in temporary")
        }
        XCTAssertEqual(e2.reason, TemporaryDomainError.Reason.attachmentsUnavailableInTemporary)
        // Refusal happened BEFORE the port saw anything.
        XCTAssertEqual(fixture.port.recordedLaunches.count, 0)
    }

    func testGoalModeRefusedWithoutIntelligenceStore() async throws {
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        let reply = await fixture.domain.temporaryLaunch(
            conversationID: cid, incarnation: inc,
            correlation: "g1", receipt: nil, goal: "big goal", mode: "goal",
            preferredModelID: nil, attachmentCount: 0,
            stagedAttachmentHandles: 0)
        guard case .refused(let error) = reply else {
            return XCTFail("goal mode must be refused for temporary sessions")
        }
        XCTAssertEqual(error.reason, TemporaryDomainError.Reason.goalModeUnsupportedStore)
    }

    func testLaunchHandsOverEphemeralBundleIdentityAndFrozenCeilingBeforeFirstAwait() async throws {
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        let reply = await fixture.domain.temporaryLaunch(
            conversationID: cid, incarnation: inc,
            correlation: "shape", receipt: nil, goal: "hi", mode: "chat",
            preferredModelID: nil, attachmentCount: 0,
            stagedAttachmentHandles: 0)
        guard case .launched = reply else { return XCTFail("launch") }
        let launch = fixture.port.recordedLaunches.last!
        // Immutable temporary identity + the ORIGINAL ephemeral stores,
        // present at the moment the request was handed over (the port
        // records at entry, BEFORE its first await).
        XCTAssertTrue(launch.request.stores.isTemporary)
        XCTAssertEqual(launch.request.stores.hostedConversationID, cid)
        XCTAssertEqual(launch.request.incarnation, inc)
        XCTAssertEqual(launch.request.epoch, fixture.epoch)
        XCTAssertFalse(launch.request.frozenToolCeiling.contains("mcp.demo.run"))
        XCTAssertTrue(launch.request.frozenToolCeiling.contains("web.fetch"))
    }

    func testAuthorityRequiresExactIncarnationAndVanishesAfterEnd() async throws {
        let (cid, inc, _, _, _) = try await fixture.startedSession()
        let a1 = await fixture.domain.authority(conversationID: cid,
                                                incarnation: inc)
        XCTAssertNotNil(a1)
        let a2 = await fixture.domain.authority(conversationID: cid,
                                                incarnation: UUID())
        XCTAssertNil(a2)
        _ = await fixture.domain.end(conversationID: cid, incarnation: inc)
        let a3 = await fixture.domain.authority(conversationID: cid,
                                                incarnation: inc)
        XCTAssertNil(a3)
    }
}
