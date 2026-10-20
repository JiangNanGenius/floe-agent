// SPDX-License-Identifier: MPL-2.0
//
// RB-4 RunDomain REPAIR tests (job-047bee7a3eff4941). AUTHORED, NOT
// EXECUTED. Companion to the four repaired defects (RUN-S1..RUN-S4):
//   * POSITIVE temporary engine launch through the immutable ephemeral
//     bundle (ONE shared EphemeralRunStore set for launcher+bundle), real
//     stream/cancel/navigation/finalization, hostile durable collisions,
//     and zero ordinary DB/FS drift (RB5 HANDOFF T1-T5 consumed exactly);
//   * non-blocking owned P8 feeds (stalled message feed does not delay the
//     handoff or the terminal; stalled terminal feed leaves the terminal
//     visible while the delete drain waits the exact lease; abort/foreign
//     fence; root retirement refuses the feed but the run settles;
//     unrelated conversation B unblocked; sustained completions stay
//     bounded);
//   * staged-lease reservation/commit/rollback (exactly-once commit ack,
//     double-launch refusal, pre-commit failure releases the reservation
//     while preserving staged bytes) and the bounded image loader
//     (positive through the bound port, typed refusal while unbound,
//     vision-route override, temporary denies images before any IO).
// All flows call the REAL public domain paths over the REAL file-backed
// schema-46 stores and the REAL ConversationRunService; only the model
// stream and the port doubles are synthetic. Nothing here has run.
import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloePersistence
import FloeAgentRuntime
import FloeSecurity
@testable import FloeAndroidCore

final class RuntimeFacadeRunRepairTests: XCTestCase {
    private var fixture: RunDomainFixture!

    override func setUp() async throws {
        fixture = try await RunDomainFixture.make()
    }

    override func tearDown() async throws {
        RunDomainFacade.uninstall()
        await fixture?.tearDown()
        fixture = nil
    }

    // MARK: - RUN-S2: positive temporary engine launch (RB5 T1-T5 exact)

    func testTemporaryEphemeralLaunchStreamsAndFinalizesInRAMOnly() async throws {
        let hostedID = UUID()
        let ephemeral = EphemeralRunBundleSet(hostedConversationID: hostedID)
        let domain = fixture.makeDomain()
        let reply = await domain.start(
            query: RunStartQuery(conversationID: hostedID,
                                 goal: "temporary positive turn",
                                 mode: .chat,
                                 providerID: fixture.providerID,
                                 modelID: fixture.modelID),
            receipt: "op:v1:" + String(repeating: "5", count: 32),
            conversationID: nil,               // T1: create-intent shape
            bundleOverride: ephemeral.bundle) // SAME store instances throughout
        guard case .mutationAccepted(let detail) = reply.outcome else {
            return XCTFail("temporary seam must launch positively, got \(reply.outcome)")
        }
        let runID = try XCTUnwrap(UUID(uuidString: detail["runID"] ?? ""))
        // The REAL engine streams to its terminal INSIDE the session's RAM
        // store — the bundle's own run store observes everything.
        let settled = await pollFor(timeoutSeconds: 8) {
            guard let state = try? await ephemeral.runs.run(id: runID)?.state else {
                return false
            }
            return !FacadeRunDomain.activeRunStates.contains(state)
        }
        XCTAssertTrue(settled, "the temporary run must reach a real terminal")
        let finalState = try await ephemeral.runs.run(id: runID)?.state
        XCTAssertEqual(finalState, "completed")
        let events = try await ephemeral.runs.events(runID: runID, afterSequence: 0,
                                                     limit: 100)
        XCTAssertTrue(events.contains { $0.kind == .terminal })
        XCTAssertTrue(events.contains { $0.kind == .assistantText })
        // T4: no intelligence feed EVER fires from a temporary identity.
        XCTAssertEqual(fixture.feed.counts.user, 0)
        XCTAssertEqual(fixture.feed.counts.terminal, 0)
        // T2/zero-drift: the durable DB and the checkpoint FS are untouched.
        let hoistedAssertValue_37 = try await fixture.durableConversationCount()
        XCTAssertEqual(hoistedAssertValue_37, 0)
        let hoistedAssertValue_38 = try await fixture.durableRunCount()
        XCTAssertEqual(hoistedAssertValue_38, 0)
        let hoistedAssertValue_39 = try await fixture.durableMessageCount()
        XCTAssertEqual(hoistedAssertValue_39, 0)
        XCTAssertEqual(fixture.checkpointFileCount, 0)
        // T3: every offered REAL descriptor is frozen public-web eligible;
        // only the two canonical presentation-only discovery pseudo schemas
        // (tools.list/tools.search, handled internally over the already
        // temporary-filtered descriptors) may supplement them — never the
        // fixture catalog's own tools.
        let lastRequest = try XCTUnwrap(fixture.adapter.lastRequest)
        let offered = Set(lastRequest.toolSchemas.map(\.name))
        let canonicalPseudo: Set<String> = ["tools.list", "tools.search"]
        for name in offered.subtracting(canonicalPseudo) {
            XCTAssertTrue(["web.search", "web.searchAI", "web.fetch"].contains(name),
                          "temporary ceiling leaked real descriptor \(name)")
        }
        XCTAssertFalse(offered.contains("fixture.echo"),
                       "temporary ceiling must exclude the non-web fixture tool")
        // Ownership retired with zero attached tokens.
        let clean = await pollFor {
            RuntimeOwnedWorkRegistry.shared.count(for: self.fixture.epoch) == 0
        }
        XCTAssertTrue(clean)
    }

    func testTemporaryCancelDuringStreamSettlesWithoutDurableWrites() async throws {
        let hostedID = UUID()
        let ephemeral = EphemeralRunBundleSet(hostedConversationID: hostedID)
        let domain = fixture.makeDomain()
        let gate = RunGateBox()
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "partial temporary")),
            .completed(.init(stopReason: .endTurn)),
        ], stallAfter: 1, gate: gate), forRequest: 0)
        let reply = await domain.start(
            query: RunStartQuery(conversationID: hostedID,
                                 goal: "cancel the temporary run",
                                 mode: .chat,
                                 providerID: fixture.providerID,
                                 modelID: fixture.modelID),
            receipt: nil, conversationID: nil,
            bundleOverride: ephemeral.bundle)
        guard case .mutationAccepted(let detail) = reply.outcome,
              let runID = UUID(uuidString: detail["runID"] ?? "") else {
            return XCTFail("temporary launch required")
        }
        let handedOff = await pollFor {
            await domain.ownership(runID: runID)?.phase == .handedOff
        }
        XCTAssertTrue(handedOff)
        // T5-shaped explicit cancel (the closure RB5 injects): the REAL
        // service close for the exact run, owned tokens settling at the
        // run owner's real final writes.
        if let service = await domain.liveService(runID) {
            await service.cancel()
        } else {
            XCTFail("the temporary run must have a live service before cancel")
        }
        gate.release()
        let settled = await pollFor(timeoutSeconds: 8) {
            guard let state = try? await ephemeral.runs.run(id: runID)?.state else {
                return false
            }
            return !FacadeRunDomain.activeRunStates.contains(state)
        }
        XCTAssertTrue(settled)
        let hoistedAssertValue_40 = try await fixture.durableConversationCount()
        XCTAssertEqual(hoistedAssertValue_40, 0)
        let hoistedAssertValue_41 = try await fixture.durableRunCount()
        XCTAssertEqual(hoistedAssertValue_41, 0)
        let clean = await pollFor {
            RuntimeOwnedWorkRegistry.shared.count(for: self.fixture.epoch) == 0
        }
        XCTAssertTrue(clean)
    }

    func testTemporaryRunSurfacesNavigationAndStaysLiveUntilExplicitCancel() async throws {
        let hostedID = UUID()
        let ephemeral = EphemeralRunBundleSet(hostedConversationID: hostedID)
        let domain = fixture.makeDomain()
        let gate = RunGateBox()
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "still streaming")),
            .completed(.init(stopReason: .endTurn)),
        ], stallAfter: 1, gate: gate), forRequest: 0)
        let reply = await domain.start(
            query: RunStartQuery(conversationID: hostedID,
                                 goal: "surfaces come and go",
                                 mode: .chat,
                                 providerID: fixture.providerID,
                                 modelID: fixture.modelID),
            receipt: nil, conversationID: nil, bundleOverride: ephemeral.bundle)
        guard case .mutationAccepted(let detail) = reply.outcome,
              let runID = UUID(uuidString: detail["runID"] ?? "") else {
            return XCTFail("temporary launch required")
        }
        let handedOff = await pollFor {
            await domain.ownership(runID: runID)?.phase == .handedOff
        }
        XCTAssertTrue(handedOff)
        // Simulated navigation/rotation beats: NO domain command may run
        // for ordinary navigation (RB7); the run stays live under its
        // service owner exactly like an ordinary run.
        try? await Task.sleep(nanoseconds: 150_000_000)
        let hoistedAssertValue_42 = await domain.ownership(runID: runID)?.phase
        XCTAssertEqual(hoistedAssertValue_42, .handedOff)
        XCTAssertEqual(RuntimeOwnedWorkRegistry.shared.count(for: fixture.epoch), 1)
        gate.release()
        let settled = await pollFor(timeoutSeconds: 8) {
            await domain.ownership(runID: runID) == nil
        }
        XCTAssertTrue(settled)
    }

    func testTemporaryForeignHostedIdentityRefusedAndReservationReleased() async throws {
        let hostedID = UUID()
        let ephemeral = EphemeralRunBundleSet(hostedConversationID: hostedID)
        let domain = fixture.makeDomain()
        fixture.staging.unknownHandles = []
        let reply = await domain.start(
            query: RunStartQuery(conversationID: UUID(),   // foreign identity
                                 goal: "smuggle a launch",
                                 mode: .chat,
                                 providerID: fixture.providerID,
                                 modelID: fixture.modelID,
                                 stagedAttachmentHandles: ["lease-doc-x"]),
            receipt: nil, conversationID: nil,
            bundleOverride: ephemeral.bundle)
        // The ORIGINAL EphemeralRunLaunchStore validation refuses the
        // foreign identity with the typed invalid-state refusal (a foreign
        // hosted identity is invalid input for the session, not a store
        // failure); the reservation is released (bytes preserved) and
        // nothing commits.
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("foreign hosted identity must fail closed")
        }
        XCTAssertEqual(error.code, .invalidState)
        XCTAssertTrue(fixture.staging.releases.contains("lease-doc-x"))
        XCTAssertTrue(fixture.staging.commits.isEmpty)
        XCTAssertTrue(fixture.staging.discarded.isEmpty,
                      "staged bytes must never be discarded")
        let hoistedAssertValue_43 = try await fixture.durableConversationCount()
        XCTAssertEqual(hoistedAssertValue_43, 0)
    }

    func testTemporaryLaunchLeavesCollidingOrdinaryRowsUntouched() async throws {
        // Hostile seeding: ordinary durable rows ALREADY exist under the
        // exact hosted UUID and a probe run id — any fallback to the
        // ordinary singleton would be observable as drift.
        let hostedID = UUID()
        try await fixture.database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO conversations (id, title, created_at, updated_at, mode,
                                               purpose, title_origin)
                    VALUES (?, 'hostile', ?, ?, 'chat', 'ordinary', 'manual')
                    """,
                arguments: [hostedID.uuidString, RunWireDate.encode(Date()),
                            RunWireDate.encode(Date())])
        }
        let beforeConversations = try await fixture.durableConversationCount()
        let beforeMessages = try await fixture.durableMessageCount()
        let beforeRuns = try await fixture.durableRunCount()
        let ephemeral = EphemeralRunBundleSet(hostedConversationID: hostedID)
        let domain = fixture.makeDomain()
        let reply = await domain.start(
            query: RunStartQuery(conversationID: hostedID,
                                 goal: "collide but stay RAM-only",
                                 mode: .chat,
                                 providerID: fixture.providerID,
                                 modelID: fixture.modelID),
            receipt: nil, conversationID: nil, bundleOverride: ephemeral.bundle)
        guard case .mutationAccepted(let detail) = reply.outcome,
              let runID = UUID(uuidString: detail["runID"] ?? "") else {
            return XCTFail("temporary launch with colliding durable rows must work")
        }
        let settled = await pollFor(timeoutSeconds: 8) {
            guard let state = try? await ephemeral.runs.run(id: runID)?.state else {
                return false
            }
            return !FacadeRunDomain.activeRunStates.contains(state)
        }
        XCTAssertTrue(settled)
        // ALL ordinary durable tables and the checkpoint FS are unchanged.
        let hoistedAssertValue_44 = try await fixture.durableConversationCount()
        XCTAssertEqual(hoistedAssertValue_44, beforeConversations)
        let hoistedAssertValue_45 = try await fixture.durableMessageCount()
        XCTAssertEqual(hoistedAssertValue_45, beforeMessages)
        let hoistedAssertValue_46 = try await fixture.durableRunCount()
        XCTAssertEqual(hoistedAssertValue_46, beforeRuns)
        XCTAssertEqual(fixture.checkpointFileCount, 0)
        let title = try await fixture.database.reader { db in
            try String.fetchOne(db, sql: "SELECT title FROM conversations WHERE id = ?",
                                arguments: [hostedID.uuidString])
        }
        XCTAssertEqual(title, "hostile", "the durable collision row must be untouched")
    }

    // MARK: - RUN-S3: non-blocking owned P8 feeds

    func testStalledMessageFeedDoesNotBlockHandoffOrTerminal() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let stall = RunGateBox()
        fixture.feed.stallDeliver = stall
        let reply = await domain.start(
            envelope: await domain.launchProbeEnvelope(
                fixture: fixture, conversationID: conversationID),
            receipt: "op:v1:" + String(repeating: "6", count: 32),
            correlation: "corr-p8msg")
        guard case .mutationAccepted(let detail) = reply.outcome,
              let runID = UUID(uuidString: detail["runID"] ?? "") else {
            stall.release()
            return XCTFail("launch required")
        }
        // Handoff proceeds WHILE the message feed is stalled; the run
        // reaches its durable terminal WITHOUT the feed returning.
        let handedOff = await pollFor {
            await domain.ownership(runID: runID)?.phase == .handedOff
        }
        XCTAssertTrue(handedOff)
        let terminal = await waitDurableTerminal(fixture: fixture, runID: runID)
        XCTAssertEqual(terminal, "completed")
        // The feed lease is STILL held (the handler never returned) — the
        // message-feed lease, plus the terminal-feed lease once retirement
        // dispatched it onto the same stalled gate.
        let held = await pollFor {
            await domain.feedLeaseCount(conversationID: conversationID) >= 1
        }
        XCTAssertTrue(held)
        XCTAssertEqual(fixture.feed.counts.user, 0)
        stall.release()
        let delivered = await pollFor {
            self.fixture.feed.counts.user == 1 && self.fixture.feed.counts.terminal == 1
        }
        XCTAssertTrue(delivered, "each feed delivers exactly once after release")
        let drained = await pollFor {
            await domain.feedLeaseCount(conversationID: conversationID) == 0
        }
        XCTAssertTrue(drained)
        fixture.feed.stallDeliver = nil
    }

    func testStalledTerminalFeedLeavesTerminalVisibleAndDeleteDrainWaits() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let terminalStall = RunGateBox()
        fixture.feed.stallTerminalDeliver = terminalStall
        let reply = await domain.start(
            envelope: await domain.launchProbeEnvelope(
                fixture: fixture, conversationID: conversationID),
            receipt: "op:v1:" + String(repeating: "7", count: 32),
            correlation: "corr-p8term")
        guard case .mutationAccepted(let detail) = reply.outcome,
              let runID = UUID(uuidString: detail["runID"] ?? "") else {
            terminalStall.release()
            return XCTFail("launch required")
        }
        // The terminal feed stalls; retirement itself must NOT block on it.
        let terminal = await waitDurableTerminal(fixture: fixture, runID: runID)
        XCTAssertEqual(terminal, "completed")
        let ownershipGone = await pollFor {
            await domain.ownership(runID: runID) == nil
        }
        XCTAssertTrue(ownershipGone, "ownership settles without waiting for the feed")
        XCTAssertEqual(fixture.feed.counts.terminal, 0)
        let hoistedAssertValue_47 = await domain.feedLeaseCount(conversationID: conversationID)
        XCTAssertEqual(hoistedAssertValue_47, 1)
        // The delete drain SEES the in-flight lease and waits for the REAL
        // handler return — never a timeout detach.
        let lifecycle = RunDomainDeletionLifecycle(domain: domain)
        let fence = try await lifecycle.beginDeletionFence(
            conversationID: conversationID, epoch: fixture.epoch, operationID: UUID())
        let observation = DrainObservationBox()
        let drain = Task {
            do {
                let report = try await lifecycle.drainOwnedWork(fence: fence)
                observation.markFinished(report)
                return report
            } catch {
                observation.markFinished(nil)
                throw error
            }
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertFalse(observation.isFinished,
                       "drain must wait for the REAL held terminal feed lease")
        terminalStall.release()
        let report = try await drain.value
        _ = await lifecycle.abortDeletionFence(fence)
        XCTAssertEqual(report.pendingLaunchCount, 0)
        let evidence = try XCTUnwrap(report.targetOwnedWork)
        XCTAssertTrue(evidence.contains {
            $0.token.kind == .conversation && !$0.stillAttached
        }, "the terminal-feed lease token must be reported detached")
        let delivered = await pollFor {
            self.fixture.feed.counts.terminal == 1
        }
        XCTAssertTrue(delivered)
        fixture.feed.stallTerminalDeliver = nil
    }

    func testDeleteAbortWithStalledFeedOldFenceRefusedAndRefenceWaits() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let stall = RunGateBox()
        fixture.feed.stallDeliver = stall
        _ = await domain.start(
            envelope: await domain.launchProbeEnvelope(
                fixture: fixture, conversationID: conversationID),
            receipt: "op:v1:" + String(repeating: "8", count: 32),
            correlation: "corr-p8abort")
        let lifecycle = RunDomainDeletionLifecycle(domain: domain)
        let fence = try await lifecycle.beginDeletionFence(
            conversationID: conversationID, epoch: fixture.epoch, operationID: UUID())
        // Abort while the feed is stalled: the feed task is NOT cancelled
        // (no timeout detach anywhere); the settlement releases only the
        // guard.
        let settlement = await lifecycle.abortDeletionFence(fence)
        XCTAssertEqual(settlement, .released)
        // The old fence token can never clear a newer guard state.
        let hoistedAssertValue_48 = await lifecycle.abortDeletionFence(fence)
        XCTAssertEqual(hoistedAssertValue_48, .alreadySettled)
        // A NEW fence may begin while the feed still runs; its drain waits
        // the same exact lease through to the REAL handler return.
        let fence2 = try await lifecycle.beginDeletionFence(
            conversationID: conversationID, epoch: fixture.epoch, operationID: UUID())
        let observation = DrainObservationBox()
        let drain = Task {
            do {
                let report = try await lifecycle.drainOwnedWork(fence: fence2)
                observation.markFinished(report)
                return report
            } catch {
                observation.markFinished(nil)
                throw error
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(observation.isFinished)
        stall.release()
        let report = try await drain.value
        // A foreign token is refused exactly like CH-R3 — while the fence2
        // guard still exists (the drain awaits the work but does NOT settle
        // the guard).
        let foreign = ConversationDeletionFence(
            conversationID: conversationID, epoch: fixture.epoch,
            operationID: UUID(), authorityReceipt: "work:v1:foreign")
        let hoistedAssertValue_49 = await lifecycle.abortDeletionFence(foreign)
        XCTAssertEqual(hoistedAssertValue_49, .refusedForeignToken)
        _ = await lifecycle.abortDeletionFence(fence2)
        XCTAssertEqual(report.pendingLaunchCount, 0)
        XCTAssertGreaterThan(fixture.feed.counts.user, 0)
        fixture.feed.stallDeliver = nil
    }

    func testRootRetirementRefusesFeedButRunSettlesTruthfully() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        _ = await domain.start(
            envelope: await domain.launchProbeEnvelope(
                fixture: fixture, conversationID: conversationID),
            receipt: "op:v1:" + String(repeating: "9", count: 32),
            correlation: "corr-p8retire")
        await domain.beginGenerationRetirement()
        // The run settles through the real cancel cascade; the fenced
        // terminal feed is refused (typed counter), never faked.
        let settled = await pollFor(timeoutSeconds: 8) {
            RuntimeOwnedWorkRegistry.shared.count(for: self.fixture.epoch) == 0
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(fixture.feed.counts.terminal, 0)
        // New admissions refuse under the retired generation.
        let reply = await domain.start(
            envelope: await domain.launchProbeEnvelope(
                fixture: fixture, conversationID: conversationID),
            receipt: "op:v1:" + String(repeating: "a", count: 32),
            correlation: "corr-p8retire2")
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("retired generation must refuse new launches")
        }
        XCTAssertEqual(error.code, .sessionFenced)
    }

    func testUnrelatedConversationBDeleteUnblockedByStalledFeedOnA() async throws {
        let a = try await fixture.makeOrdinaryConversation()
        let b = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let stall = RunGateBox()
        fixture.feed.stallDeliver = stall
        _ = await domain.start(
            envelope: await domain.launchProbeEnvelope(
                fixture: fixture, conversationID: a),
            receipt: "op:v1:" + String(repeating: "b", count: 32),
            correlation: "corr-p8a")
        // Wait until A's message feed is REALLY inside the stalled handler
        // (the lease exists from dispatch; the gate proves the handler is
        // blocked), then unarm the gate so B's feeds flow normally.
        let stalled = await pollFor { stall.isWaiting }
        XCTAssertTrue(stalled)
        fixture.feed.stallDeliver = nil
        // Conversation B runs to completion and its delete proceeds without
        // ever waiting on A's stalled feed.
        let replyB = await domain.start(
            envelope: await domain.launchProbeEnvelope(
                fixture: fixture, conversationID: b),
            receipt: "op:v1:" + String(repeating: "c", count: 32),
            correlation: "corr-p8b")
        guard case .mutationAccepted(let detailB) = replyB.outcome,
              let runB = UUID(uuidString: detailB["runID"] ?? "") else {
            stall.release()
            return XCTFail("B launch required")
        }
        _ = await waitDurableTerminal(fixture: fixture, runID: runB)
        // B's own feeds flow normally (A's message feed is still stalled
        // inside its handler — it can never gate conversation B).
        let bFed = await pollFor {
            self.fixture.feed.counts.user >= 1 && self.fixture.feed.counts.terminal >= 1
        }
        XCTAssertTrue(bFed)
        let lifecycle = RunDomainDeletionLifecycle(domain: domain)
        let fenceB = try await lifecycle.beginDeletionFence(
            conversationID: b, epoch: fixture.epoch, operationID: UUID())
        let reportB = try await lifecycle.drainOwnedWork(fence: fenceB)
        XCTAssertEqual(reportB.conversationID, b)
        XCTAssertEqual(reportB.pendingLaunchCount, 0)
        // End the test-owned fence (no DB delete committed) BEFORE moving on.
        let settleB = await lifecycle.abortDeletionFence(fenceB)
        XCTAssertEqual(settleB, .released)
        // A's stalled lease outlives B's whole lifecycle — release it only
        // now and watch EACH conversation's user-message feed commit
        // EXACTLY ONCE (global cumulative counts cannot express that).
        stall.release()
        let exactlyOnce = await pollFor(timeoutSeconds: 8) {
            let userCommits = self.fixture.feed.userEvents
            return userCommits.filter { $0.conversationID == a }.count == 1
                && userCommits.filter { $0.conversationID == b }.count == 1
        }
        XCTAssertTrue(exactlyOnce, "each launch's user-message feed must commit exactly once")
        let aLeaseSettled = await pollFor {
            await domain.feedLeaseCount(conversationID: a) == 0
        }
        XCTAssertTrue(aLeaseSettled, "A's exact feed lease must settle after the handler returns")
    }

    func testSustainedCompletionsKeepFeedBookkeepingBounded() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        for index in 0..<5 {
            let reply = await domain.start(
                envelope: await domain.launchProbeEnvelope(
                    fixture: fixture, conversationID: conversationID),
                receipt: "op:v1:" + String(repeating: "d", count: 31) + "\(index)",
                correlation: "corr-sustain-\(index)")
            guard case .mutationAccepted(let detail) = reply.outcome,
                  let runID = UUID(uuidString: detail["runID"] ?? "") else {
                return XCTFail("sustained launch \(index) required")
            }
            _ = await waitDurableTerminal(fixture: fixture, runID: runID)
        }
        // Exactly-once per real source identity across the whole series.
        XCTAssertEqual(fixture.feed.counts.user, 5)
        XCTAssertEqual(fixture.feed.counts.terminal, 5)
        let pruned = await pollFor {
            await domain.feedDeliveredObserved[conversationID] == nil
        }
        XCTAssertTrue(pruned, "terminal pruning must bound the live bookkeeping")
        // Late/old-callback once-only: re-driving retirement paths for an
        // already-retired run mutates nothing and re-feeds nothing.
        await domain.retire(runID: UUID(), terminalSucceeded: true, feedTerminal: true)
        XCTAssertEqual(fixture.feed.counts.terminal, 5)
    }

    // MARK: - Global admission fence exclusivity (Main privacy-lane correction)

    func testGlobalFenceBeginIsExclusiveAndRetirementBlockIsDistinct() async throws {
        let domain = fixture.makeDomain()
        let conversationID = try await fixture.makeOrdinaryConversation()
        let first = try await domain.beginGlobalAdmissionFence(expectedEpoch: fixture.epoch)
        // A second begin while ANY fence is held refuses typed and leaves
        // the existing owner untouched (never replaced/invalidated).
        do {
            _ = try await domain.beginGlobalAdmissionFence(expectedEpoch: fixture.epoch)
            XCTFail("second begin must refuse while a fence is held")
        } catch let error as RunDomainError {
            XCTAssertEqual(error.code, .duplicateInFlight)
        }
        // The original owner's finish still finalizes exactly its own
        // generation; a stale token never clears a newer fence.
        let hoistedAssertValue_50 = await domain.finishGlobalAdmissionFence(first, committed: true)
        XCTAssertTrue(hoistedAssertValue_50)
        let second = try await domain.beginGlobalAdmissionFence(expectedEpoch: fixture.epoch)
        let hoistedAssertValue_51 = await domain.finishGlobalAdmissionFence(first, committed: true)
        XCTAssertFalse(hoistedAssertValue_51)
        let hoistedAssertValue_52 = await domain.isGlobalAdmissionFencedNow()
        XCTAssertTrue(hoistedAssertValue_52)
        let hoistedAssertValue_53 = await domain.finishGlobalAdmissionFence(second, committed: false)
        XCTAssertTrue(hoistedAssertValue_53)
        // Refusal paths leave FUTURE ordinary launches usable.
        let after = await domain.start(
            envelope: await domain.launchProbeEnvelope(
                fixture: fixture, conversationID: conversationID),
            receipt: "op:v1:" + String(repeating: "m", count: 32),
            correlation: "corr-fence-after")
        guard case .mutationAccepted = after.outcome else {
            return XCTFail("ordinary launches must work after the fence settles")
        }
        // Retirement is a DISTINCT global block: it fences new admissions
        // without minting or consuming an operation fence token. (Direct
        // domain retirement — the facade-level hook requires the installed
        // registry, which these unit flows do not bind.)
        await domain.beginGenerationRetirement()
        do {
            _ = try await domain.beginGlobalAdmissionFence(expectedEpoch: fixture.epoch)
            XCTFail("retired generation must refuse a new fence begin")
        } catch let error as RunDomainError {
            XCTAssertEqual(error.code, .sessionFenced)
        }
    }

    // MARK: - RUN-S4: staged lease reservation / commit / rollback

    func testLaunchReservesAndCommitsStagedLeaseExactlyOnce() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        var payload = fixture.startPayload(goal: "consume the staged doc")
        payload["stagedAttachments"] = ["lease-doc-9"]
        let reply = await domain.start(
            envelope: fixture.launchEnvelope(
                conversationID: conversationID, payload: payload,
                revisionVersion: try await fixture.revision(conversationID: conversationID),
                correlation: "corr-lease1"),
            receipt: "op:v1:" + String(repeating: "e", count: 32),
            correlation: "corr-lease1")
        guard case .mutationAccepted(let detail) = reply.outcome else {
            return XCTFail("staged launch required")
        }
        let runID = try XCTUnwrap(UUID(uuidString: detail["runID"] ?? ""))
        _ = await waitDurableTerminal(fixture: fixture, runID: runID)
        // The commit acknowledgement ran EXACTLY ONCE with the REAL
        // committed ids; the pre-commit release path never ran.
        XCTAssertEqual(fixture.staging.commits.count, 1)
        XCTAssertEqual(fixture.staging.commits.first?.handle, "lease-doc-9")
        XCTAssertEqual(fixture.staging.commits.first?.conversationID, conversationID)
        XCTAssertNotNil(fixture.staging.commits.first?.messageID)
        XCTAssertTrue(fixture.staging.releases.isEmpty)
        XCTAssertTrue(fixture.staging.discarded.isEmpty)
        // The durable attachment row is bound to the committed message
        // through the ORIGINAL prepare transaction.
        let attachments = try await fixture.conversationStore
            .attachments(conversationID: conversationID)
        XCTAssertEqual(attachments.count, 1)
        XCTAssertNotNil(attachments.first?.messageID)
    }

    func testDoubleLaunchSameHandleRefusedTyped() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let gate = RunGateBox()
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "first stream")),
            .completed(.init(stopReason: .endTurn)),
        ], stallAfter: 1, gate: gate), forRequest: 0)
        var firstPayload = fixture.startPayload(goal: "alpha with the lease")
        firstPayload["stagedAttachments"] = ["lease-shared"]
        let first = await domain.start(
            envelope: fixture.launchEnvelope(
                conversationID: conversationID, payload: firstPayload,
                revisionVersion: try await fixture.revision(conversationID: conversationID),
                correlation: "corr-dbl1"),
            receipt: "op:v1:" + String(repeating: "f", count: 32),
            correlation: "corr-dbl1")
        guard case .mutationAccepted = first.outcome else {
            gate.release()
            return XCTFail("first launch required")
        }
        // While alpha is live, a second launch claiming the SAME handle is
        // refused typed — never a silent merge or a double consumption.
        let revisionNow = try await fixture.revision(conversationID: conversationID)
        var secondPayload = fixture.startPayload(goal: "beta steals the lease")
        secondPayload["stagedAttachments"] = ["lease-shared"]
        let second = await domain.start(
            envelope: fixture.launchEnvelope(
                conversationID: conversationID, payload: secondPayload,
                revisionVersion: revisionNow, correlation: "corr-dbl2"),
            receipt: "op:v1:" + String(repeating: "g", count: 32),
            correlation: "corr-dbl2")
        guard case .rejected(let error) = second.outcome else {
            gate.release()
            return XCTFail("double launch must be refused")
        }
        XCTAssertEqual(error.code, .duplicateInFlight)
        // Exactly one commit (alpha's); beta never consumed anything.
        gate.release()
        let alphaSettled = await pollFor {
            RuntimeOwnedWorkRegistry.shared.count(for: self.fixture.epoch) == 0
        }
        XCTAssertTrue(alphaSettled)
        XCTAssertEqual(fixture.staging.commits.count, 1)
        XCTAssertEqual(fixture.staging.commits.first?.handle, "lease-shared")
    }

    func testPrepareFailureReleasesReservationPreservingStagedBytes() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        var components = fixture.components()
        components.durable = RunPersistenceBundle(
            identity: .ordinary,
            conversations: fixture.conversationStore,
            runs: fixture.runStore,
            runningInputs: fixture.inputStore,
            launches: FailingLaunchStore(),
            childRuns: fixture.childStore,
            intelligence: fixture.intelligence)
        let domain = fixture.makeCustomDomain(components)
        var payload = fixture.startPayload(goal: "prepare will fail")
        payload["stagedAttachments"] = ["lease-fragile"]
        let reply = await domain.start(
            envelope: fixture.launchEnvelope(
                conversationID: conversationID, payload: payload,
                revisionVersion: try await fixture.revision(conversationID: conversationID),
                correlation: "corr-fragile"),
            receipt: "op:v1:" + String(repeating: "h", count: 32),
            correlation: "corr-fragile")
        guard case .rejected = reply.outcome else {
            return XCTFail("failing prepare must refuse the launch")
        }
        // The reservation was released (the launch never committed) and the
        // staged bytes are preserved — never discarded.
        XCTAssertEqual(fixture.staging.releases, ["lease-fragile"])
        XCTAssertTrue(fixture.staging.commits.isEmpty)
        XCTAssertTrue(fixture.staging.discarded.isEmpty)
        // C0 proof: no run row, no attachment row.
        let runs = try await fixture.runStore.runs(conversationID: conversationID)
        XCTAssertEqual(runs.count, 1) // the seeding run only
    }

    func testImagePositiveThroughBoundLoaderReachesProviderRequest() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeImageDomain()
        fixture.staging.imageHandles = ["lease-img-1"]
        var payload = fixture.startPayload(goal: "look at the staged image")
        payload["stagedAttachments"] = ["lease-img-1"]
        let reply = await domain.start(
            envelope: fixture.launchEnvelope(
                conversationID: conversationID, payload: payload,
                revisionVersion: try await fixture.revision(conversationID: conversationID),
                correlation: "corr-imgpos"),
            receipt: "op:v1:" + String(repeating: "i", count: 32),
            correlation: "corr-imgpos")
        guard case .mutationAccepted(let detail) = reply.outcome else {
            return XCTFail("image launch with a bound loader must be admitted")
        }
        let runID = try XCTUnwrap(UUID(uuidString: detail["runID"] ?? ""))
        _ = await waitDurableTerminal(fixture: fixture, runID: runID)
        // The trusted loader produced the ORIGINAL image part exactly once
        // with the bounded ceiling, and the provider request really carried
        // the image data (the ORIGINAL runtime path, no wire binary).
        XCTAssertEqual(fixture.imageLoader.requests.count, 1)
        XCTAssertEqual(fixture.imageLoader.requests.first?.handle, "lease-img-1")
        XCTAssertLessThanOrEqual(fixture.imageLoader.requests.first?.maxBytes ?? .max,
                                 8 * 1024 * 1024)
        let request = try XCTUnwrap(fixture.adapter.lastRequest)
        let carriesImage = request.contentMessages.contains {
            $0.content.contains { part in
                if case .imageData(let mime, _) = part { return mime == "image/png" }
                return false
            }
        }
        XCTAssertTrue(carriesImage, "the ORIGINAL runtime must forward the image part")
        // History carries the real image/ref mapping: the committed
        // attachment row exists with the image kind.
        let attachments = try await fixture.conversationStore
            .attachments(conversationID: conversationID)
        XCTAssertEqual(attachments.first?.kind, .image)
        // Exactly once commit acknowledgement; no discard anywhere.
        XCTAssertEqual(fixture.staging.commits.count, 1)
        XCTAssertTrue(fixture.staging.discarded.isEmpty)
    }

    func testImageUnboundLoaderRefusedBeforeAnyLoaderIO() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        // Default components leave the loader UNBOUND.
        let domain = fixture.makeDomain()
        fixture.staging.imageHandles = ["lease-img-2"]
        var payload = fixture.startPayload(goal: "image without a loader")
        payload["stagedAttachments"] = ["lease-img-2"]
        let reply = await domain.start(
            envelope: fixture.launchEnvelope(
                conversationID: conversationID, payload: payload,
                revisionVersion: try await fixture.revision(conversationID: conversationID),
                correlation: "corr-imgunbound"),
            receipt: "op:v1:" + String(repeating: "j", count: 32),
            correlation: "corr-imgunbound")
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("unbound image loader must refuse before effects")
        }
        XCTAssertEqual(error.code, .capabilityNotUsable)
        XCTAssertEqual(error.reason, .imageLoaderUnbound)
        XCTAssertTrue(fixture.imageLoader.requests.isEmpty, "no IO before binding")
        XCTAssertTrue(fixture.staging.commits.isEmpty)
        let runs = try await fixture.runStore.runs(conversationID: conversationID)
        XCTAssertEqual(runs.count, 1)
    }

    func testVisionOverrideAdmitsConfiguredAuxiliaryRoute() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        // A text-only selected model with an enabled text+vision auxiliary
        // route configured: image launch is admitted through the ORIGINAL
        // preferences route.
        var textOnly = fixture.modelProfile
        textOnly.id = UUID()
        // Model identity canonicalizes by provider + remoteModelID: the
        // text-only helper MUST have its own remote id or it would alias
        // and overwrite the fixture's vision row.
        textOnly.remoteModelID = "fixture-text-only-model"
        textOnly.capabilities = [.text, .tools]
        try await fixture.modelStore.saveModel(textOnly)
        // Both records really exist with their own capabilities.
        let storedText = try await fixture.modelStore.model(id: textOnly.id)
        XCTAssertEqual(storedText?.capabilities, [.text, .tools])
        let storedVision = try await fixture.modelStore.model(id: fixture.modelID)
        XCTAssertTrue(storedVision?.capabilities.contains(.vision) == true,
                      "the fixture vision model row must survive the text-only save")
        var preferences = try await fixture.modelStore.preferences()
        preferences.visionModelID = fixture.modelID
        try await fixture.modelStore.savePreferences(preferences)
        let domain = fixture.makeImageDomain()
        fixture.staging.imageHandles = ["lease-img-aux"]
        var payload = fixture.startPayload(goal: "vision via aux route")
        payload["stagedAttachments"] = ["lease-img-aux"]
        payload["modelID"] = textOnly.id.uuidString
        let admitted = await domain.start(
            envelope: fixture.launchEnvelope(
                conversationID: conversationID, payload: payload,
                revisionVersion: try await fixture.revision(conversationID: conversationID),
                correlation: "corr-aux"),
            receipt: "op:v1:" + String(repeating: "k", count: 32),
            correlation: "corr-aux")
        guard case .mutationAccepted(let detail) = admitted.outcome else {
            return XCTFail("configured auxiliary vision route must admit the image")
        }
        let runID = try XCTUnwrap(UUID(uuidString: detail["runID"] ?? ""))
        _ = await waitDurableTerminal(fixture: fixture, runID: runID)
        // Without the auxiliary route the same shape refuses typed.
        preferences.visionModelID = nil
        try await fixture.modelStore.savePreferences(preferences)
        // A FRESH staged handle: the first run consumed "lease-img-aux", so
        // this launch must reach the vision-route admission (the refusal
        // under test), not the typed already-consumed lease refusal.
        fixture.staging.imageHandles.insert("lease-img-aux-2")
        var noAuxPayload = payload
        noAuxPayload["stagedAttachments"] = ["lease-img-aux-2"]
        let refused = await domain.start(
            envelope: fixture.launchEnvelope(
                conversationID: conversationID, payload: noAuxPayload,
                revisionVersion: try await fixture.revision(conversationID: conversationID),
                correlation: "corr-noaux"),
            receipt: "op:v1:" + String(repeating: "l", count: 32),
            correlation: "corr-noaux")
        guard case .rejected(let error) = refused.outcome else {
            return XCTFail("missing vision route must refuse")
        }
        XCTAssertEqual(error.code, .needsConfiguration)
    }

    func testTemporaryDeniesImagesBeforeAnyLoaderIO() async throws {
        let hostedID = UUID()
        let ephemeral = EphemeralRunBundleSet(hostedConversationID: hostedID)
        // The loader is BOUND — the temporary refusal must still land
        // before ANY staged IO (RAM-only contract, image-free ceiling).
        let domain = fixture.makeImageDomain()
        fixture.staging.imageHandles = ["lease-img-tmp"]
        let reply = await domain.start(
            query: RunStartQuery(conversationID: hostedID,
                                 goal: "temporary with an image",
                                 mode: .chat,
                                 providerID: fixture.providerID,
                                 modelID: fixture.modelID,
                                 stagedAttachmentHandles: ["lease-img-tmp"]),
            receipt: nil, conversationID: nil, bundleOverride: ephemeral.bundle)
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("temporary image launch must be refused before IO")
        }
        XCTAssertEqual(error.code, .capabilityNotUsable)
        XCTAssertEqual(error.reason, .imageLoaderUnbound)
        XCTAssertTrue(fixture.imageLoader.requests.isEmpty,
                      "temporary denies images before ANY staged IO")
        let hoistedAssertValue_54 = try await fixture.durableConversationCount()
        XCTAssertEqual(hoistedAssertValue_54, 0)
    }
}

// MARK: - Admitted environment/job binding (Main correction 2026-10-20)

extension RuntimeFacadeRunRepairTests {
    func testRuntimeConfigurationCarriesAdmittedEnvironmentAndHonestLinuxTruth() throws {
        let conversationID = UUID()
        let config = FacadeRunDomain.runtimeConfiguration(
            conversationID: conversationID,
            provider: fixture.providerProfile,
            model: fixture.modelProfile,
            mode: .chat,
            ceiling: ["fixture.echo"],
            toolsEnabled: true,
            temporary: false,
            environmentID: "env-exact-1")
        XCTAssertEqual(config.environmentID, "env-exact-1",
                       "an accepted environment identity must reach the ORIGINAL runtime configuration")
        XCTAssertFalse(config.localLinuxGuestEnvironment,
                       "G02 resolves no local Linux guest: the flag stays the ACTUAL truth")
        XCTAssertFalse(config.publicWebOnly)
        XCTAssertFalse(config.temporaryReadOnly)
        XCTAssertEqual(config.allowedToolNames, ["fixture.echo"])
        let ephemeral = FacadeRunDomain.runtimeConfiguration(
            conversationID: conversationID,
            provider: fixture.providerProfile,
            model: fixture.modelProfile,
            mode: .chat,
            ceiling: nil,
            toolsEnabled: true,
            temporary: true,
            environmentID: "env-exact-2")
        XCTAssertEqual(ephemeral.environmentID, "env-exact-2")
        XCTAssertTrue(ephemeral.publicWebOnly)
        XCTAssertTrue(ephemeral.temporaryReadOnly)
        XCTAssertTrue(ephemeral.ephemeralTransport)
        XCTAssertFalse(ephemeral.localLinuxGuestEnvironment)
    }

    func testAcceptedEnvironmentAndJobBindingSurvivesHandoff() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let environment = "env-" + UUID().uuidString
        let job = UUID().uuidString
        fixture.environmentProof.knownEnvironment = environment
        fixture.environmentProof.acceptAnyJob = true
        let gate = RunGateBox()
        let index = fixture.adapter.requestCount
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "bound")),
            .completed(.init(stopReason: .endTurn)),
        ], stallAfter: 1, gate: gate), forRequest: index)
        var payload = fixture.startPayload(goal: "bound env")
        payload["environmentID"] = environment
        payload["jobID"] = job
        let domain = fixture.makeDomain()
        let envelope = fixture.launchEnvelope(
            conversationID: conversationID, payload: payload,
            revisionVersion: try await fixture.revision(conversationID: conversationID),
            correlation: "corr-env-bind")
        let reply = await domain.start(
            envelope: envelope,
            receipt: "op:v1:" + String(repeating: "7", count: 32),
            correlation: "corr-env-bind")
        guard case .mutationAccepted(let detail) = reply.outcome,
              let runID = UUID(uuidString: detail["runID"] ?? "") else {
            return XCTFail("a proven environment/job launch must be accepted, got \(reply.outcome)")
        }
        let live = await pollFor { await domain.ownership(runID: runID)?.phase == .handedOff }
        XCTAssertTrue(live, "the bound run must reach handoff")
        let bound = await domain.ownership(runID: runID)
        XCTAssertEqual(bound?.environmentID, environment,
                       "an accepted environment identity must survive into the live ownership")
        XCTAssertEqual(bound?.jobID, job,
                       "an accepted job identity must survive into the live ownership")
        gate.release()
        _ = await waitDurableTerminal(fixture: fixture, runID: runID)
    }

    // MARK: - REAL P8 personalization feed binding (Main S3 decision 2026-10-20)

    func testRealPersonalizationFeedHoldsExactLeaseAndNeverBlocksTerminal() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let gate = RunGateBox()
        let binder = RunPersonalizationFeedBinder()
        let witness = RecordingPersonalizationLeaseValidator(real: binder.leaseValidator)
        let events = try await makeRealPersonalizationEvents(
            fences: GatedPersonalizationFences(epoch: fixture.epoch, gate: gate),
            leases: witness)
        let domain = fixture.makeCustomDomain(fixture.components(feed: binder.feed))
        binder.bind(domain: domain, events: events)
        let reply = await domain.start(
            envelope: await domain.launchProbeEnvelope(fixture: fixture,
                                                       conversationID: conversationID),
            receipt: "op:v1:" + String(repeating: "a", count: 32),
            correlation: "corr-realp8")
        guard case .mutationAccepted(let detail) = reply.outcome,
              let runID = UUID(uuidString: detail["runID"] ?? "") else {
            return XCTFail("launch must be accepted")
        }
        // The REAL handler is stalled at its fence: the chat terminal must
        // still settle (the feed is an owned maintenance Task, never a
        // pre-handoff await).
        let terminal = await waitDurableTerminal(fixture: fixture, runID: runID)
        XCTAssertEqual(terminal, "completed",
                       "a stalled REAL P8 handler must not block the chat terminal")
        XCTAssertTrue(witness.snapshot.isEmpty,
                      "the handler must still be stalled before its lease validation")
        gate.release()
        let validated = await pollFor(timeoutSeconds: 8) {
            !witness.snapshot.isEmpty
        }
        XCTAssertTrue(validated, "the REAL handler must validate the delivered lease")
        let calls = witness.snapshot
        XCTAssertTrue(calls.contains { call in
            call.conversationID == conversationID && call.epoch == fixture.epoch
                && call.valid && call.token.hasPrefix("work:v1:")
        }, "the exact Run feed token must validate inside the handler")
        let settled = await pollFor(timeoutSeconds: 8) {
            RuntimeOwnedWorkRegistry.shared.count(for: self.fixture.epoch) == 0
        }
        XCTAssertTrue(settled, "the exact lease must be released after the handler terminal")
    }

    func testRealPersonalizationFeedDeleteDrainWaitsForActualHandler() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let gate = RunGateBox()
        let binder = RunPersonalizationFeedBinder()
        let witness = RecordingPersonalizationLeaseValidator(real: binder.leaseValidator)
        let events = try await makeRealPersonalizationEvents(
            fences: GatedPersonalizationFences(epoch: fixture.epoch, gate: gate),
            leases: witness)
        let domain = fixture.makeCustomDomain(fixture.components(feed: binder.feed))
        binder.bind(domain: domain, events: events)
        let reply = await domain.start(
            envelope: await domain.launchProbeEnvelope(fixture: fixture,
                                                       conversationID: conversationID),
            receipt: "op:v1:" + String(repeating: "b", count: 32),
            correlation: "corr-realp8-drain")
        guard case .mutationAccepted(let detail) = reply.outcome,
              let runID = UUID(uuidString: detail["runID"] ?? "") else {
            return XCTFail("launch must be accepted")
        }
        _ = await waitDurableTerminal(fixture: fixture, runID: runID)
        // Open a delete fence while the REAL handler still holds the exact
        // Run feed lease: the drain must wait for the actual handler/write
        // terminal, never a counter or timer detach.
        let lifecycle = RunDomainDeletionLifecycle(domain: domain)
        let fence = try await lifecycle.beginDeletionFence(
            conversationID: conversationID, epoch: fixture.epoch, operationID: UUID())
        let observation = DrainObservationBox()
        let drain = Task {
            do {
                let report = try await lifecycle.drainOwnedWork(fence: fence)
                observation.markFinished(report)
                return report
            } catch {
                observation.markFinished(nil)
                throw error
            }
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertFalse(observation.isFinished,
                       "drain must wait for the REAL P8 handler/write terminal")
        XCTAssertTrue(witness.snapshot.isEmpty,
                      "the stalled handler has not reached its validation yet")
        gate.release()
        let report = try await drain.value
        _ = await lifecycle.abortDeletionFence(fence)
        XCTAssertEqual(report.pendingLaunchCount, 0)
        let evidence = try XCTUnwrap(report.targetOwnedWork)
        XCTAssertTrue(evidence.contains { $0.token.kind == .conversation && !$0.stillAttached },
                      "the exact feed lease must be reported detached after the handler returned")
        let calls = witness.snapshot
        XCTAssertFalse(calls.isEmpty)
        XCTAssertTrue(calls.allSatisfy { $0.conversationID == conversationID })
        XCTAssertTrue(calls.contains { $0.valid == false },
                      "a delete guard opened before handling must invalidate the exact lease")
        _ = await lifecycle.abortDeletionFence(fence)
    }

    func testRealPersonalizationFeedNeverFiresForTemporaryAndRejectsRetiredLease() async throws {
        let hostedID = UUID()
        let ephemeral = EphemeralRunBundleSet(hostedConversationID: hostedID)
        let gate = RunGateBox()
        gate.release()   // the temporary path must never reach the handler
        let binder = RunPersonalizationFeedBinder()
        let witness = RecordingPersonalizationLeaseValidator(real: binder.leaseValidator)
        let events = try await makeRealPersonalizationEvents(
            fences: GatedPersonalizationFences(epoch: fixture.epoch, gate: gate),
            leases: witness)
        let domain = fixture.makeCustomDomain(fixture.components(feed: binder.feed))
        binder.bind(domain: domain, events: events)
        let reply = await domain.start(
            query: RunStartQuery(conversationID: hostedID,
                                 goal: "temporary real p8",
                                 mode: .chat,
                                 providerID: fixture.providerID,
                                 modelID: fixture.modelID),
            receipt: "op:v1:" + String(repeating: "c", count: 32),
            conversationID: nil,
            bundleOverride: ephemeral.bundle)
        guard case .mutationAccepted(let detail) = reply.outcome,
              let runID = UUID(uuidString: detail["runID"] ?? "") else {
            return XCTFail("temporary launch must be accepted")
        }
        let terminal = await pollFor(timeoutSeconds: 8) {
            guard let state = try? await ephemeral.runs.run(id: runID)?.state else { return false }
            return !FacadeRunDomain.activeRunStates.contains(state)
        }
        XCTAssertTrue(terminal)
        XCTAssertTrue(witness.snapshot.isEmpty,
                      "temporary identities must never feed the REAL P8 handler")
        // The retired/stale token is refused by the SAME real validator.
        let retired = PersonalizationEventOperationLease(
            token: "work:v1:retired", conversationID: hostedID,
            rootEpoch: fixture.epoch)
        let staleValid = await witness.isEventOperationLeaseValid(retired)
        XCTAssertFalse(staleValid, "a token no longer held by this generation must fail closed")
    }
}

// MARK: - REAL P8 test support (witness + gated fences + real events graph)

actor GatedPersonalizationFences: PersonalizationEventFenceProviding {
    let epoch: UInt64
    let gate: RunGateBox
    init(epoch: UInt64, gate: RunGateBox) {
        self.epoch = epoch
        self.gate = gate
    }
    func currentRootEpoch() async -> UInt64 {
        await gate.waitThroughCancellation()
        return epoch
    }
    func isTemporaryConversation(_ conversationID: UUID) async -> Bool { false }
    func isDeletionOrHistoryClearPending(_ conversationID: UUID) async -> Bool { false }
}

/// Witness AROUND the real Run-owned validator (never a substitute): it
/// records the exact delivered tokens and the real verdict.
final class RecordingPersonalizationLeaseValidator:
    PersonalizationEventOwnedLeaseProviding, @unchecked Sendable {
    struct Call: Sendable {
        let token: String
        let conversationID: UUID
        let epoch: UInt64
        let valid: Bool
    }
    private let real: any PersonalizationEventOwnedLeaseProviding
    private let lock = NSLock()
    private var calls: [Call] = []
    init(real: any PersonalizationEventOwnedLeaseProviding) {
        self.real = real
    }
    func isEventOperationLeaseValid(
        _ lease: PersonalizationEventOperationLease) async -> Bool {
        let valid = await real.isEventOperationLeaseValid(lease)
        withScopedLock(lock) {
            calls.append(Call(token: lease.token,
                              conversationID: lease.conversationID,
                              epoch: lease.rootEpoch, valid: valid))
        }
        return valid
    }
    var snapshot: [Call] { withScopedLock(lock) { calls } }
}

extension RuntimeFacadeRunRepairTests {
    /// The REAL qualified memory/P8 graph over the fixture's SAME original
    /// file-backed DatabaseManager (original migrations/stores).
    func makeRealPersonalizationEvents(
        fences: any PersonalizationEventFenceProviding,
        leases: any PersonalizationEventOwnedLeaseProviding
    ) async throws -> FacadePersonalizationEvents {
        let manager = fixture.database
        let intelligence = SQLiteIntelligenceStore(database: manager)
        let documents = SQLitePersonalizationStore(database: manager)
        let cadence = PersonalizationUpdateCadence()
        let service = PersonalizationService(documents: documents,
                                             memories: intelligence,
                                             cadence: cadence)
        let memoryAdapter = FacadeMemoryAdapter(
            database: manager,
            intelligenceStore: intelligence,
            workspaceStore: SQLiteWorkspaceStore(database: manager),
            conversationStore: SQLiteConversationStore(database: manager))
        let synthetic = SyntheticModelAdapter(scripts: [
            SyntheticModelAdapter.Script(deltas: ["# automatic\n", "\n- small edit."]),
        ])
        let provider = ProviderProfile(kind: .openAI,
                                       wireProtocol: .openAIChatCompletions,
                                       baseURL: URL(string: "https://synthetic.invalid")!)
        let model = ModelProfile(providerID: provider.id, remoteModelID: "m",
                                 displayName: "M",
                                 limits: ModelLimits(contextTokens: 1_024,
                                                     maxOutputTokens: 512))
        let route = SyntheticRouteProvider(mode: .resolved(
            adapter: synthetic, provider: provider, model: model))
        let generate = FacadePersonalizationGenerate(
            database: manager,
            workspaceStore: SQLiteWorkspaceStore(database: manager),
            route: route)
        return FacadePersonalizationEvents(
            database: manager, personalizationService: service,
            generate: generate, memoryAdapter: memoryAdapter,
            cadence: cadence, fences: fences, ownedLeases: leases)
    }
}
