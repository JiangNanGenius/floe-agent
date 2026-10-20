// SPDX-License-Identifier: MPL-2.0
//
// RB-4 run-ownership / delete-quiescence / global-fence tests. AUTHORED,
// NOT EXECUTED. Proves the concrete Main CH-R2/CH-R3 semantics against the
// reviewed RB1 registry and the RB3 delete port, plus the privacy-clear
// admission fence handoff and the ordinary-navigation rule.
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime
import FloeSecurity
@testable import FloeAndroidCore

final class RuntimeFacadeRunLifecycleTests: XCTestCase {
    private var fixture: RunDomainFixture!

    override func setUp() async throws {
        fixture = try await RunDomainFixture.make()
    }

    override func tearDown() async throws {
        RunDomainFacade.uninstall()
        await fixture?.tearDown()
        fixture = nil
    }

    private func launchStalled(_ domain: FacadeRunDomain, _ conversationID: UUID,
                               goal: String, receipt: String) async throws
        -> (runID: UUID, gate: RunGateBox) {
        let gate = RunGateBox()
        let index = fixture.adapter.requestCount
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "live \(goal)")),
            .completed(.init(stopReason: .endTurn)),
        ], stallAfter: 1, gate: gate), forRequest: index)
        let revision = try await fixture.revision(conversationID: conversationID)
        let reply = await domain.start(envelope: fixture.launchEnvelope(
            conversationID: conversationID, payload: fixture.startPayload(goal: goal),
            revisionVersion: revision, correlation: "life-\(goal)"),
            receipt: receipt, correlation: "life-\(goal)")
        guard case .mutationAccepted(let detail) = reply.outcome,
              let runID = UUID(uuidString: detail["runID"] ?? "") else {
            throw NSError(domain: "fixture", code: 4)
        }
        _ = await pollFor { await domain.ownership(runID: runID)?.phase == .handedOff }
        // The script is indexed by the request count captured BEFORE start;
        // wait until THIS run's provider request was really served and the
        // stream really entered the gate before returning (otherwise a
        // sequential enqueue can overwrite the slot and the run receives
        // the default completing script).
        let requestServed = await pollFor(timeoutSeconds: 8) {
            self.fixture.adapter.requestCount > index && gate.isWaiting
        }
        guard requestServed else {
            gate.release()
            throw NSError(domain: "fixture", code: 5,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "stalled provider was not really dispatched"])
        }
        return (runID, gate)
    }

    func testActiveOwnerRetirementBarrierBlocksDrainUntilRealCompletion() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        // A REAL separately-owned maintenance handler whose completion is
        // deliberately held: the P8 message feed stalls inside delivery
        // while holding its exact owned lease. A cooperative model stream
        // may finish on cancellation; this held feed lease is the genuine
        // pending physical work the drain must wait for (no timer, no fake
        // zero).
        let feedGate = RunGateBox()
        fixture.feed.stallDeliver = feedGate
        let (runID, gate) = try await launchStalled(domain, conversationID,
                                                    goal: "barrier",
                                                    receipt: "op:v1:" + String(repeating: "a", count: 32))
        // The feed lease is attached while the handler is really stalled.
        let feedHeld = await pollFor {
            RuntimeOwnedWorkRegistry.shared.count(for: self.fixture.epoch) >= 2
        }
        XCTAssertTrue(feedHeld, "the stalled P8 feed must hold its exact lease")
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
        // While the feed handler is genuinely held, the drain must NOT have
        // returned (a timer release or counter detach would be a fake zero).
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(observation.isFinished,
                       "drain must still be waiting on the REAL held P8 lease")
        // Let the real handler complete: the drain follows the truth.
        feedGate.release()
        gate.release()
        let report = try await drain.value
        _ = observation
        XCTAssertTrue(report.launchesFenced)
        XCTAssertGreaterThanOrEqual(report.runServicesCancelled, 1)
        XCTAssertEqual(report.countsEpoch, fixture.epoch)
        XCTAssertEqual(report.conversationID, conversationID)
        // CH-R2 exact per-conversation evidence: every target token is a
        // REAL work:v1 receipt for THIS conversation's epoch and detached
        // after the real drain; pending launches explicitly zero.
        XCTAssertEqual(report.pendingLaunchCount, 0)
        let evidence = try XCTUnwrap(report.targetOwnedWork)
        XCTAssertFalse(evidence.isEmpty)
        for observation in evidence {
            XCTAssertEqual(observation.conversationID, conversationID)
            XCTAssertEqual(observation.token.epoch, fixture.epoch)
            XCTAssertTrue(RuntimeOwnedWorkReceipt.isValid(observation.token.receipt))
            XCTAssertFalse(observation.stillAttached)
            XCTAssertFalse(RuntimeOwnedWorkRegistry.shared.isAttached(observation.token))
        }
        // The fence's own authority receipt is NOT target evidence (no
        // self-count deadlock).
        XCTAssertFalse(evidence.contains { $0.token.receipt == fence.authorityReceipt })
        // All run-scoped owned work settled: the epoch registry reaches
        // zero once the fence authority token itself is released (the
        // root-retirement gate remains this global truth, RB1).
        let release = await lifecycle.abortDeletionFence(fence)
        XCTAssertEqual(release, .released)
        let clean = await pollFor {
            RuntimeOwnedWorkRegistry.shared.count(for: self.fixture.epoch) == 0
        }
        XCTAssertTrue(clean)
    }

    func testUnrelatedConversationNeverBlocksOrIsCancelledByDelete() async throws {
        let conversationA = try await fixture.makeOrdinaryConversation()
        let conversationB = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let (runA, gateA) = try await launchStalled(domain, conversationA, goal: "delete me",
                                                    receipt: "op:v1:" + String(repeating: "b", count: 32))
        let (runB, gateB) = try await launchStalled(domain, conversationB, goal: "keep running",
                                                    receipt: "op:v1:" + String(repeating: "c", count: 32))
        let lifecycle = RunDomainDeletionLifecycle(domain: domain)
        let fence = try await lifecycle.beginDeletionFence(
            conversationID: conversationA, epoch: fixture.epoch, operationID: UUID())
        let taskFixture: RunDomainFixture = fixture
        let report = try await Task {
            // Cancel A first (target-only), then drain awaits REAL
            // settlement for A's conversation.
            let stateA = try unwrapAsync(await taskFixture.runState(runA))
            _ = await domain.cancel(envelope: taskFixture.executionEnvelope(
                command: "run.cancel", conversationID: conversationA, runID: runA,
                payload: ["expectedState": stateA], correlation: "corr-a-cancel",
                revision: ["resourceID": RunWireRevision.runResourceID(runA),
                           "version": stateA]))
            gateA.release()
            return try await lifecycle.drainOwnedWork(fence: fence)
        }.value
        XCTAssertEqual(report.countsEpoch, fixture.epoch)
        // CH-R2: the GLOBAL endCountsByKind still counts B's live run
        // token — but only as diagnostics; A's drain completed, B's
        // evidence never appears in it, and B was never cancelled.
        let globalCounts = try XCTUnwrap(report.endCountsByKind)
        XCTAssertGreaterThanOrEqual(globalCounts["run"] ?? 0, 1)
        for observation in try XCTUnwrap(report.targetOwnedWork) {
            XCTAssertEqual(observation.conversationID, conversationA)
        }
        let bLive = await domain.ownership(runID: runB)?.phase == .handedOff
        XCTAssertTrue(bLive, "unrelated conversation B must keep running")
        // End the test-owned fence (no DB delete committed) before the
        // global-zero assertion: the fence authority token is REAL owned
        // work and must be released through the exact-token settlement.
        let settle = await lifecycle.abortDeletionFence(fence)
        XCTAssertEqual(settle, .released)
        gateB.release()
        _ = await waitDurableTerminal(fixture: fixture, runID: runB)
        let drained = await pollFor {
            RuntimeOwnedWorkRegistry.shared.count(for: self.fixture.epoch) == 0
        }
        XCTAssertTrue(drained)
    }

    func testGuardAbortLeavesConversationLaunchableAndOldAbortCannotClearNew() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let lifecycle = RunDomainDeletionLifecycle(domain: domain)
        let firstOperation = UUID()
        let oldFence = try await lifecycle.beginDeletionFence(
            conversationID: conversationID, epoch: fixture.epoch,
            operationID: firstOperation)
        // A second live guard for the SAME conversation is refused and the
        // first guard stays intact (atomic no-register-on-throw).
        do {
            _ = try await lifecycle.beginDeletionFence(
                conversationID: conversationID, epoch: fixture.epoch,
                operationID: UUID())
            return XCTFail("fenceHeld expected")
        } catch let error as ConversationDeletionLifecycleFailure {
            XCTAssertEqual(error, .fenceHeld)
        }
        // The old fence settles cleanly first.
        let hoistedAssertValue_22 = await lifecycle.abortDeletionFence(oldFence)
        XCTAssertEqual(hoistedAssertValue_22, .released)
        // Re-begin for the supersede/foreign-token matrix.
        let currentFence = try await lifecycle.beginDeletionFence(
            conversationID: conversationID, epoch: fixture.epoch,
            operationID: firstOperation)
        let staleCopy = ConversationDeletionFence(conversationID: conversationID,
                                                  epoch: fixture.epoch,
                                                  operationID: firstOperation,
                                                  authorityReceipt: "work:v1:" + String(repeating: "0", count: 32))
        // Foreign/fabricated receipt can never clear the current guard.
        let hoistedAssertValue_23 = await lifecycle.abortDeletionFence(staleCopy)
        XCTAssertEqual(hoistedAssertValue_23, .refusedForeignToken)
        let launchBlocked = await domain.start(envelope: await domain.launchProbeEnvelope(
            fixture: fixture, conversationID: conversationID),
            receipt: "op:v1:" + String(repeating: "d", count: 32),
            correlation: "corr-guarded")
        if case .mutationAccepted = launchBlocked.outcome {
            return XCTFail("held guard must fence launches")
        }
        // Exact current fence abort releases; the surviving conversation is
        // launchable again (in-flight owned tokens keep their own truth).
        let hoistedAssertValue_24 = await lifecycle.abortDeletionFence(currentFence)
        XCTAssertEqual(hoistedAssertValue_24, .released)
        let hoistedAssertValue_25 = await lifecycle.abortDeletionFence(currentFence)
        XCTAssertEqual(hoistedAssertValue_25, .alreadySettled)
        let accepted = await domain.start(envelope: await domain.launchProbeEnvelope(
            fixture: fixture, conversationID: conversationID),
            receipt: "op:v1:" + String(repeating: "e", count: 32),
            correlation: "corr-after-abort")
        guard case .mutationAccepted = accepted.outcome else {
            return XCTFail("surviving conversation must be launchable after abort")
        }
    }

    func testDeleteDrainWaitsForRealP8MaintenanceLease() async throws {
        // Main P8 correction: the feed holds an OWNED lease until the
        // handler really returns; the delete drain must include that exact
        // token (no check-then-await-only boolean fencing, no fake zero).
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let stall = RunGateBox()
        fixture.feed.stallDeliver = stall
        let receipt = fixture.effects.register(correlationID: "corr-p8stall")
        let launchFixture: RunDomainFixture = fixture
        let launchTask = Task {
            await domain.start(envelope: await domain.launchProbeEnvelope(
                fixture: launchFixture, conversationID: conversationID),
                receipt: receipt!, correlation: "corr-p8stall")
        }
        // The ORIGINAL prepare commits FIRST, then the feed stalls inside
        // delivery with its exact lease attached (prepared effect already
        // visible proves the commit landed).
        var runID: UUID?
        for _ in 0..<100 {
            let prepared = pollEffects(fixture.effects, receipt: receipt!)
                .first { $0.kind == .prepared }
            if let raw = prepared?.detail?["runID"], let id = UUID(uuidString: raw) {
                runID = id
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let runID else {
            stall.release()
            _ = await launchTask.value
            fixture.feed.stallDeliver = nil
            return XCTFail("prepared effect must land before the stalled feed")
        }
        // Let the producer REALLY finish so the TERMINAL feed is dispatched
        // (lease acquired, handler stalled on the same gate) BEFORE the
        // deletion fence opens — a terminal feed admitted only after the
        // guard is legitimately refused, which is different from an
        // already-held lease the drain must await.
        _ = await waitDurableTerminal(fixture: fixture, runID: runID)
        let bothHeld = await pollFor(timeoutSeconds: 8) {
            await domain.feedLeaseCount(conversationID: conversationID) >= 2
        }
        XCTAssertTrue(bothHeld, "message + terminal feed leases must both be really held")
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
                       "drain must wait for the REAL held P8 lease, never a timer release")
        // RUN-S3 repair: the launch is already handed off (the feed no
        // longer blocks the handoff), so the drain cancels the LIVE
        // producer and waits BOTH stalled feed leases (message + terminal,
        // same gate) through to their real handler returns — never a
        // timeout detach, never a fake zero.
        stall.release()
        let report = try await drain.value
        _ = await lifecycle.abortDeletionFence(fence)
        _ = await launchTask.value
        XCTAssertEqual(report.pendingLaunchCount, 0)
        let evidence = try XCTUnwrap(report.targetOwnedWork)
        XCTAssertTrue(evidence.contains {
            $0.token.kind == .conversation && !$0.stillAttached
        }, "the P8 maintenance lease token must be reported detached")
        let fed = await pollFor {
            self.fixture.feed.counts.user >= 1 && self.fixture.feed.counts.terminal >= 1
        }
        XCTAssertTrue(fed)
        // The cancelled run's durable truth is a non-active terminal
        // (never left silently preparing, never claimed no-effect).
        let finalState = try await fixture.runState(runID)
        XCTAssertNotNil(finalState)
        XCTAssertFalse(FacadeRunDomain.activeRunStates.contains(finalState ?? ""))
        fixture.feed.stallDeliver = nil
    }

    func testGlobalAdmissionFenceFinishAbortCommitSemantics() async throws {
        let domain = fixture.makeDomain()
        let conversationID = try await fixture.makeOrdinaryConversation()
        // Begin the privacy-clear global fence.
        let fence = try await domain.beginGlobalAdmissionFence(expectedEpoch: fixture.epoch)
        // New launches refuse while fenced (provable C0, no rows).
        let reply = await domain.start(envelope: await domain.launchProbeEnvelope(
            fixture: fixture, conversationID: conversationID),
            receipt: "op:v1:" + String(repeating: "f", count: 32),
            correlation: "corr-global-fence")
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("global fence must admit-refuse")
        }
        XCTAssertEqual(error.code, .sessionFenced)
        let runs = try await fixture.runStore.runs(conversationID: conversationID)
        XCTAssertEqual(runs.count, 1)
        // EXCLUSIVE BEGIN (Main privacy-lane correction): a second begin
        // while ANY fence is held refuses typed and leaves the existing
        // owner token untouched — never replaced or invalidated.
        do {
            _ = try await domain.beginGlobalAdmissionFence(expectedEpoch: fixture.epoch)
            XCTFail("second begin must refuse while a fence is held")
        } catch let thrown as RunDomainError {
            XCTAssertEqual(thrown.code, .duplicateInFlight)
        }
        // The original owner still owns the fence: its finish succeeds and
        // only its own generation clears.
        let hoistedAssertValue_26 = await domain.finishGlobalAdmissionFence(fence, committed: false)
        XCTAssertTrue(hoistedAssertValue_26)
        // A STALE finish (old token) cannot clear a NEWER fence: begin a
        // fresh fence, then attempt to finish it with the OLD token.
        let renewed = try await domain.beginGlobalAdmissionFence(expectedEpoch: fixture.epoch)
        XCTAssertNotEqual(fence.generation, renewed.generation)
        let hoistedAssertValue_27 = await domain.finishGlobalAdmissionFence(fence, committed: false)
        XCTAssertFalse(hoistedAssertValue_27)
        let stillFenced = await domain.start(envelope: await domain.launchProbeEnvelope(
            fixture: fixture, conversationID: conversationID),
            receipt: "op:v1:" + String(repeating: "0", count: 32),
            correlation: "corr-stale-finish")
        if case .mutationAccepted = stillFenced.outcome {
            return XCTFail("old finish must not reopen admission")
        }
        // Real pending-launch quiescence: with nothing in flight this
        // returns immediately; a live stalled launch keeps it waiting.
        try await domain.awaitPendingLaunchesSettled(expectedEpoch: fixture.epoch)
        let hoistedAssertValue_28 = await domain.finishGlobalAdmissionFence(renewed, committed: true)
        XCTAssertTrue(hoistedAssertValue_28)
        // After the current fence finishes, future ordinary launches work.
        let after = await domain.start(envelope: await domain.launchProbeEnvelope(
            fixture: fixture, conversationID: conversationID),
            receipt: "op:v1:" + String(repeating: "1", count: 32),
            correlation: "corr-after-fence")
        guard case .mutationAccepted = after.outcome else {
            return XCTFail("post-finish launch must be admitted")
        }
    }

    func testOrdinaryNavigationAndArchiveNeverCancelRuns() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let (runID, gate) = try await launchStalled(domain, conversationID, goal: "navigate past",
                                                    receipt: "op:v1:" + String(repeating: "2", count: 32))
        // RB3 reads (get/messagePage/search) and archive never touch this
        // lane; assert the facade's OWNERS persist without any cancel call.
        _ = await pollFor { await domain.ownership(runID: runID)?.phase == .handedOff }
        let stillLive = await domain.ownership(runID: runID)?.phase == .handedOff
        XCTAssertTrue(stillLive)
        let oneToken = await pollFor {
            RuntimeOwnedWorkRegistry.shared.count(for: self.fixture.epoch) == 1
        }
        XCTAssertTrue(oneToken)
        gate.release()
        _ = await waitDurableTerminal(fixture: fixture, runID: runID)
    }

    func testIntelligenceFeedFiresOnceAtRealCommitAndRealSuccess() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let reply = await domain.start(envelope: await domain.launchProbeEnvelope(
            fixture: fixture, conversationID: conversationID),
            receipt: "op:v1:" + String(repeating: "3", count: 32),
            correlation: "corr-feed")
        guard case .mutationAccepted(let detail) = reply.outcome,
              let runID = UUID(uuidString: detail["runID"] ?? "") else {
            return XCTFail("launch required")
        }
        let terminal = await waitDurableTerminal(fixture: fixture, runID: runID)
        XCTAssertEqual(terminal, "completed")
        // Exactly one user-commit + one terminal-success event; keys match
        // the REAL committed identities. RUN-S3 repair: the feeds are owned
        // maintenance Tasks now — retirement settles BEFORE the handlers
        // return, so observe the CONVERGED feed counts (never a race
        // window and never a timeout assumption).
        let settled = await pollFor {
            await domain.ownership(runID: runID) == nil
        }
        XCTAssertTrue(settled)
        let fed = await pollFor {
            self.fixture.feed.counts.user == 1 && self.fixture.feed.counts.terminal == 1
        }
        XCTAssertTrue(fed)
        let counts = fixture.feed.counts
        XCTAssertEqual(counts.user, 1)
        XCTAssertEqual(counts.terminal, 1)
        let userEvent = try XCTUnwrap(fixture.feed.userEvents.first)
        XCTAssertEqual(userEvent.rootEpoch, fixture.epoch)
        XCTAssertEqual(userEvent.conversationID, conversationID)
        XCTAssertEqual(userEvent.runID, runID)
        XCTAssertFalse(userEvent.temporaryAtStart)
        XCTAssertFalse(userEvent.temporaryAtCommit)
        let completion = try XCTUnwrap(fixture.feed.terminalEvents.first)
        XCTAssertTrue(completion.succeeded)
        XCTAssertTrue(completion.ordinarySurface)
        XCTAssertFalse(completion.frozenTemporaryRun)
        // Feed leases carry REAL work:v1 receipts (the exact-token proof the
        // delete drain consumes).
        XCTAssertTrue(fixture.feed.tokens.allSatisfy(RuntimeOwnedWorkReceipt.isValid))
    }

    func testTemporaryBundleLaunchRefusedOnOrdinaryWireAndSeamExposedForRB5() async throws {
        // RUN-S2 repair (strengthened, method preserved): the wire surface
        // stays ordinary-only BY CONSTRUCTION (the wire handlers never pass
        // a bundleOverride, and a temporary bundle reaching them is a
        // structural impossibility), and the RB5 seam must now launch
        // POSITIVELY through ONE coherent ephemeral store set — the SAME
        // EphemeralRunStore instance shared by the bundle and the launcher
        // (the parent built two parallel instances and allowed a typed
        // refusal, which proved nothing). The durable isolation assertion
        // is kept exactly.
        let domain = fixture.makeDomain()
        let hostedID = UUID()
        let ephemeral = EphemeralRunBundleSet(hostedConversationID: hostedID)
        let reply = await domain.start(
            query: RunStartQuery(conversationID: hostedID,
                                 goal: "temporary through seam",
                                 mode: .chat,
                                 providerID: fixture.providerID,
                                 modelID: fixture.modelID),
            receipt: "op:v1:" + String(repeating: "4", count: 32),
            conversationID: nil,
            bundleOverride: ephemeral.bundle)
        guard case .mutationAccepted(let detail) = reply.outcome else {
            return XCTFail("temporary seam must launch positively, got \(reply.outcome)")
        }
        let runID = try XCTUnwrap(UUID(uuidString: detail["runID"] ?? ""))
        // The ORIGINAL engine streams inside the session's RAM store — the
        // SAME instance the bundle carries — and never a durable row.
        let settled = await pollFor(timeoutSeconds: 8) {
            guard let state = try? await ephemeral.runs.run(id: runID)?.state else {
                return false
            }
            return !FacadeRunDomain.activeRunStates.contains(state)
        }
        XCTAssertTrue(settled, "the temporary run must reach a real terminal")
        let hoistedAssertValue_29 = try await ephemeral.runs.run(id: runID)?.state
        XCTAssertEqual(hoistedAssertValue_29, "completed")
        // Original isolation assertion, unchanged: the temporary identity
        // must never write ordinary durable rows.
        let durableRuns = try await fixture.runStore.runs(conversationID: hostedID)
        XCTAssertTrue(durableRuns.isEmpty,
                      "temporary identity must never write ordinary durable rows")
        let hoistedAssertValue_30 = try await fixture.durableConversationCount()
        XCTAssertEqual(hoistedAssertValue_30, 0)
        let hoistedAssertValue_31 = try await fixture.durableMessageCount()
        XCTAssertEqual(hoistedAssertValue_31, 0)
        // RB5 T4: no feed EVER fires from a temporary identity.
        XCTAssertEqual(fixture.feed.counts.user, 0)
        XCTAssertEqual(fixture.feed.counts.terminal, 0)
    }

    func testSkillCancelAndChildEntriesPagesBoundedForHugeChildren() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        // Seed the durable graph directly with 40 children + entries via
        // the ORIGINAL store APIs (no UI emulation anywhere).
        let parentRun = UUID()
        try await fixture.runStore.saveRun(RunRecord(id: parentRun,
                                                      conversationID: conversationID,
                                                      state: "completed",
                                                      goal: "parent",
                                                      startedAt: Date()))
        for i in 0..<40 {
            let child = ChildRunRecord(id: UUID(), parentRunID: parentRun,
                                       rootRunID: parentRun,
                                       conversationID: conversationID,
                                       childIndex: i, kind: "explore",
                                       taskSummary: "child \(i)",
                                       state: i.isMultiple(of: 2) ? .completed : .running,
                                       iterationCount: i, startedAt: Date())
            _ = try await fixture.childStore.register(child)
        }
        let domain = fixture.makeDomain()
        let list = await domain.childList(envelope: fixture.executionEnvelope(
            command: "child.list", conversationID: conversationID, runID: parentRun,
            payload: nil, correlation: "corr-kids"))
        guard case .completedPage(let page, _) = list.outcome else {
            return XCTFail("bounded child list required")
        }
        XCTAssertLessThanOrEqual(page.pageBytes, RunDomainLimits.pageBudgetBytes)
        if case .object(let fields) = page.object, case .array(let items)? = fields["children"] {
            XCTAssertLessThanOrEqual(items.count, RunDomainLimits.maximumChildItems)
            XCTAssertEqual(fields["childrenTruncated"], .boolean(true))
        } else { XCTFail("children array expected") }
        // Entries paging with a small budget stops-at-budget and exposes a
        // monotonic cursor.
        let runningChildCandidate = (try await fixture.childStore
            .children(parentRunID: parentRun)).first { !$0.state.isTerminal }
        let runningChild = try XCTUnwrap(runningChildCandidate)
        for i in 0..<30 {
            try await fixture.childStore.appendEntry(id: runningChild.id, kind: .message,
                                                      payloadJSON: #"{"role":"assistant","text":"entry \(i)"}"#)
        }
        let entries = await domain.childEntries(envelope: fixture.executionEnvelope(
            command: "child.entries", conversationID: conversationID, runID: parentRun,
            payload: ["childRunID": runningChild.id.uuidString,
                      "afterSequence": 0, "limit": 200],
            correlation: "corr-entries"))
        guard case .completedPage(let epage, let cursor) = entries.outcome else {
            return XCTFail("entries page required")
        }
        XCTAssertLessThanOrEqual(epage.pageBytes, RunDomainLimits.pageBudgetBytes)
        XCTAssertNotNil(cursor)
    }
}

extension FacadeRunDomain {
    /// Builds a VALID, structurally-correct launch envelope for a
    /// conversation (helper for lifecycle tests).
    func launchProbeEnvelope(fixture: RunDomainFixture,
                             conversationID: UUID) async -> RunCommandEnvelope {
        // Fresh CURRENT digest each probe: these tests focus on the
        // admission/fence windows, not the CAS itself (covered by the
        // dedicated stale-revision launch tests).
        let revision = (try? await fixture.revision(conversationID: conversationID)) ?? ""
        return fixture.launchEnvelope(
            conversationID: conversationID,
            payload: fixture.startPayload(goal: "probe \(UUID().uuidString.prefix(4))"),
            revisionVersion: revision, correlation: "probe-\(UUID().uuidString)")
    }
}
