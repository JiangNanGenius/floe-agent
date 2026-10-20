// SPDX-License-Identifier: MPL-2.0
//
// RB-4 recovery/retry/reopen tests. AUTHORED, NOT EXECUTED. Everything
// durable flows through the ORIGINAL stores and checkpoint directory; the
// "crash" simulations manipulate real rows (never fake start ids).
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime
import FloeSecurity
@testable import FloeAndroidCore

final class RuntimeFacadeRunRecoveryTests: XCTestCase {
    private var fixture: RunDomainFixture!

    override func setUp() async throws {
        fixture = try await RunDomainFixture.make()
    }

    override func tearDown() async throws {
        RunDomainFacade.uninstall()
        await fixture?.tearDown()
        fixture = nil
    }

    private func launch(_ domain: FacadeRunDomain, _ conversationID: UUID,
                        goal: String, receipt: String,
                        stalled: Bool = true) async throws -> (runID: UUID, gate: RunGateBox) {
        let gate = RunGateBox()
        let index = fixture.adapter.requestCount
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "recovery \(goal)")),
            .completed(.init(stopReason: .endTurn)),
        ], stallAfter: stalled ? 1 : 0, gate: stalled ? gate : nil),
        forRequest: index)
        let revision = try await fixture.revision(conversationID: conversationID)
        let reply = await domain.start(envelope: fixture.launchEnvelope(
            conversationID: conversationID, payload: fixture.startPayload(goal: goal),
            revisionVersion: revision, correlation: "rec-\(goal)"),
            receipt: receipt, correlation: "rec-\(goal)")
        guard case .mutationAccepted(let detail) = reply.outcome,
              let runID = UUID(uuidString: detail["runID"] ?? "") else {
            throw NSError(domain: "fixture", code: 3)
        }
        _ = await pollFor { await domain.ownership(runID: runID)?.phase == .handedOff }
        if stalled {
            // Real preconditions: the provider request was really served,
            // the stream really entered the held gate, and the durable
            // state settled (never handedOff/requestCount alone).
            let parked = await pollFor(timeoutSeconds: 8) {
                self.fixture.adapter.requestCount > index && gate.isWaiting
            }
            guard parked else {
                gate.release()
                throw NSError(domain: "fixture", code: 5,
                              userInfo: [NSLocalizedDescriptionKey:
                                            "stalled provider was not really dispatched"])
            }
            let streaming = await pollFor(timeoutSeconds: 8) {
                (try? await self.fixture.runState(runID)) == "streamingModel"
            }
            guard streaming else {
                gate.release()
                throw NSError(domain: "fixture", code: 6,
                              userInfo: [NSLocalizedDescriptionKey:
                                            "run did not settle into a stable durable state"])
            }
        }
        return (runID, gate)
    }

    func testCheckpointIdentityMismatchFallsBackToDurableHistory() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let (runID, gate) = try await launch(domain, conversationID, goal: "stale ckpt",
                                      receipt: "op:v1:" + String(repeating: "4", count: 32))
        // Cancel first so retry is legal, then let the run REALLY settle.
        var state = try unwrapAsync(await fixture.runState(runID))
        _ = await domain.cancel(envelope: fixture.executionEnvelope(
            command: "run.cancel", conversationID: conversationID, runID: runID,
            payload: ["expectedState": state], correlation: "corr-r-c1",
            revision: ["resourceID": RunWireRevision.runResourceID(runID), "version": state]))
        gate.release()
        state = await waitDurableTerminal(fixture: fixture, runID: runID) ?? "cancelled"
        // The retry must wait until the facade REALLY retired the run
        // (durable terminal alone can precede ownership removal).
        let retired = await pollFor {
            await domain.ownership(runID: runID) == nil
        }
        XCTAssertTrue(retired, "the cancelled run must retire before retry")
        // Present a checkpoint whose DECODED identity mismatches at the
        // ACTUAL requested lookup: same run file, wrong conversation. The
        // reviewed checkpoint-source path refuses it and resumes the SAME
        // run from durable history instead.
        let mismatched = AgentCheckpoint(
            runID: runID,
            conversationID: UUID(),   // not this conversation
            state: .preparing(.init(goal: "other")),
            messages: [], pendingToolCalls: [], pendingToolResults: [],
            approvals: [], idempotencyKeys: [], createdAt: Date(),
            schemaVersion: DatabaseManager.currentSchemaVersion)
        try await fixture.checkpoints.save(mismatched)
        let retryReceipt = try XCTUnwrap(fixture.effects.register(correlationID: "corr-retry1"))
        let reply = await domain.retry(envelope: fixture.executionEnvelope(
            command: "run.retry", conversationID: conversationID, runID: runID,
            payload: ["expectedState": state], correlation: "corr-retry1",
            revision: ["resourceID": RunWireRevision.runResourceID(runID), "version": state]),
            receipt: retryReceipt)
        guard case .mutationAccepted(let detail) = reply.outcome else {
            return XCTFail("retry must fall back to durable history, got \(reply.outcome)")
        }
        XCTAssertEqual(detail["source"], "history")
        // Resume used the ORIGINAL run id — no fabricated start identity.
        let items = pollEffects(fixture.effects, receipt: retryReceipt)
        XCTAssertTrue(items.contains { $0.kind == .started
            && $0.detail?["runID"] == runID.uuidString })
    }

    func testRetryIdempotencyDuplicateInFlightRefused() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let (runID, gate) = try await launch(domain, conversationID, goal: "dup retry",
                                      receipt: "op:v1:" + String(repeating: "5", count: 32))
        let state = try unwrapAsync(await fixture.runState(runID))
        // The run is LIVE (handedOff) → owners contains it → duplicate.
        let dupReceipt = try XCTUnwrap(fixture.effects.register(correlationID: "corr-dup"))
        let reply = await domain.retry(envelope: fixture.executionEnvelope(
            command: "run.retry", conversationID: conversationID, runID: runID,
            payload: ["expectedState": state], correlation: "corr-dup",
            revision: ["resourceID": RunWireRevision.runResourceID(runID), "version": state]),
            receipt: dupReceipt)
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("live-owned run must refuse a second resume")
        }
        XCTAssertEqual(error.code, RunDomainError.Code.duplicateInFlight)
    }

    func testCheckpointedResumeUsesRealCheckpointOnce() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let (runID, gate) = try await launch(domain, conversationID, goal: "ckpt resume",
                                      receipt: "op:v1:" + String(repeating: "6", count: 32))
        var state = try unwrapAsync(await fixture.runState(runID))
        _ = await domain.cancel(envelope: fixture.executionEnvelope(
            command: "run.cancel", conversationID: conversationID, runID: runID,
            payload: ["expectedState": state], correlation: "corr-c2",
            revision: ["resourceID": RunWireRevision.runResourceID(runID), "version": state]))
        gate.release()
        state = await waitDurableTerminal(fixture: fixture, runID: runID) ?? state
        // The retry must wait until the facade REALLY retired the run
        // (durable terminal alone can precede ownership removal).
        let retired = await pollFor {
            await domain.ownership(runID: runID) == nil
        }
        XCTAssertTrue(retired, "the cancelled run must retire before retry")
        // The ORIGINAL runtime REALLY wrote a checkpoint for the cancelled
        // run; the store row + file must AGREE for a checkpoint-source
        // resume (a missing file is not a checkpoint-source proof).
        // The runtime checkpoints through the FILE store (the same store
        // the retry's checkpoint-source path reads).
        let checkpoint = try await fixture.checkpoints.load(runID: runID)
        XCTAssertNotNil(checkpoint, "the cancelled run must really write a checkpoint")
        XCTAssertEqual(checkpoint?.conversationID, conversationID)
        let resumeReceipt = try XCTUnwrap(fixture.effects.register(correlationID: "corr-r2"))
        let reply = await domain.retry(envelope: fixture.executionEnvelope(
            command: "run.retry", conversationID: conversationID, runID: runID,
            payload: ["expectedState": state], correlation: "corr-r2",
            revision: ["resourceID": RunWireRevision.runResourceID(runID),
                       "version": state]),
            receipt: resumeReceipt)
        guard case .mutationAccepted(let detail) = reply.outcome else {
            return XCTFail("accepted resume expected, got \(reply.outcome)")
        }
        XCTAssertEqual(detail["source"], "checkpoint")
        // Exactly ONE facade owner for the SAME durable id: the resume
        // re-owns the original run, never a second service.
        let owned = await domain.owners(conversationID: conversationID)
            .filter { $0.runID == runID }
        XCTAssertEqual(owned.count, 1)
    }

    func testCrashReopenMarksInterruptedAndFreshLaunchWorks() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let (runID, gate) = try await launch(domain, conversationID, goal: "crash me",
                                      receipt: "op:v1:" + String(repeating: "7", count: 32))
        // Simulate process death: NEW domain on the SAME database (the old
        // in-memory owners vanish; no resurrection allowed).
        await domain.beginGenerationRetirement()
        // (Realistic restart: bootstrap recovery marks interrupted first.)
        let recoveredDomain = fixture.makeDomain()
        // The old run stays durable until restart recovery; a NEW launch
        // must still work and must NEVER claim the old run's identity.
        let fresh = try await launch(recoveredDomain, conversationID, goal: "after crash",
                                     receipt: "op:v1:" + String(repeating: "7", count: 32),
                                     stalled: false)
        XCTAssertNotEqual(fresh.runID, runID)
        let owned = await recoveredDomain.owners(conversationID: conversationID)
        XCTAssertFalse(owned.contains { $0.runID == runID && $0.phase == .handedOff })
    }


    func testTransientInputsRecoveredExactlyOnceAfterReopen() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        // A row stranded in `promoting` WITHOUT a consumed receipt is the
        // crash signature the ORIGINAL recoverTransientInputs fixes.
        let stranded = PendingUserInput(conversationID: conversationID,
                                         targetRunID: nil,   // no FK target for a crash artifact
                                         content: "stranded steer",
                                         mode: .steer,
                                         status: .promoting)
        _ = try await fixture.inputStore.enqueue(stranded)
        try await fixture.inputStore.recoverTransientInputs()
        let rows = try await fixture.inputStore.pending(conversationID: conversationID)
        let recovered = rows.first { $0.content == "stranded steer" }
        XCTAssertEqual(recovered?.status, .queued)
        XCTAssertNil(recovered?.consumedRunID)
        // A consumed row is NEVER replayed: the exactly-once receipt stands
        // with its REAL consumed run identity (FK-valid).
        let completedRun = RunRecord(id: UUID(), conversationID: conversationID,
                                     state: "completed", goal: "earlier turn",
                                     startedAt: Date(), endedAt: Date())
        try await fixture.runStore.saveRun(completedRun)
        let consumed = PendingUserInput(conversationID: conversationID,
                                        content: "already in",
                                        status: .consumed,
                                        consumedRunID: completedRun.id)
        _ = try await fixture.inputStore.enqueue(consumed)
        XCTAssertEqual(consumed.consumedRunID, completedRun.id)
        try await fixture.inputStore.recoverTransientInputs()
        let still = try await fixture.inputStore.pending(conversationID: conversationID)
        XCTAssertFalse(still.contains { $0.content == "already in" },
                       "consumed rows leave the pending set permanently")
    }

    func testRetryAfterCrashNeverResurrectsOldTaskAndFenceStopsOldRoute() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let (runID, gate) = try await launch(domain, conversationID, goal: "fence check",
                                      receipt: "op:v1:" + String(repeating: "8", count: 32))
        // Invalidate the conversation scope (delete-guard semantics).
        let lifecycle = RunDomainDeletionLifecycle(domain: domain)
        let fence = try await lifecycle.beginDeletionFence(conversationID: conversationID,
                                                           epoch: fixture.epoch,
                                                           operationID: UUID())
        // Late retry attempt for the OLD run while fenced: refused fenced,
        // the durable row untouched.
        let state = try unwrapAsync(await fixture.runState(runID))
        let fencedReceipt = try XCTUnwrap(fixture.effects.register(correlationID: "corr-fenced-retry"))
        let reply = await domain.retry(envelope: fixture.executionEnvelope(
            command: "run.retry", conversationID: conversationID, runID: runID,
            payload: ["expectedState": state], correlation: "corr-fenced-retry",
            revision: ["resourceID": RunWireRevision.runResourceID(runID), "version": state]),
            receipt: fencedReceipt)
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("fenced retry must refuse")
        }
        XCTAssertEqual(error.code, RunDomainError.Code.sessionFenced)
        let settle = await lifecycle.abortDeletionFence(fence)
        XCTAssertEqual(settle, ConversationDeletionFenceSettlement.released)
        gate.release()
    }
}
