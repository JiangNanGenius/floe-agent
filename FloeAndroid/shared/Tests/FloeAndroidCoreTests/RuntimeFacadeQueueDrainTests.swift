// SPDX-License-Identifier: MPL-2.0
//
// G04R2 queue-input repair regressions (job-2905fd05a73e4eba). AUTHORED,
// NOT EXECUTED in the worker lane (no build authority); Main runs them in
// the combined batch (FloeAndroidCoreTests target, same module imports and
// fixture idioms as RuntimeFacadeRunControlTests).
//
// Covers the real defects proven by device evidence
// (entry/C03_QUEUE_NATIVE_EXPERIMENT_RESULT.json,
// device/c03-q-native-{edited,saved,reopen}.xml,
// device/c03-queue-edit-cancel.xml):
//
//  1. DURABLE `run.input.edit`/`run.input.remove` envelope grammar. The
//     native row CAS is `pendingInput.<UPPER uuid>/<inputVersion>`
//     (`mutateInput`); the former native conversation-row digest
//     pre-check demanded a mutually exclusive second resource from the
//     same single envelope revision, so NO envelope could pass and every
//     durable queued Save was a rejected no-op preserving the original.
//     Pinned both ways: the row revision applies the edit; a stale row
//     version and the OLD conversation-resource envelope are refused with
//     the original body byte-intact.
//  2. `run.queue` persists the composer's REAL executionMode (additive
//     grammar; absent key keeps the historical "agent" default).
//  3. The queued-input terminal drain (iOS ConversationCenter:5456
//     parity; `claimNextQueued` previously had ZERO Android production
//     callers): a real completed ordinary terminal claims the next queued
//     row and launches it through the ORIGINAL start pipeline with the
//     durable `markConsumed` receipt — WITH its resolved attachments
//     (trusted internal pre-resolved seam; never launched without them,
//     never stranded because of them) and its persisted mode; an
//     unresolvable EXPLICIT model selection refuses WITHOUT a silent
//     default fallback (iOS providerAndModel parity) and restores the row.
//  4. The lost-wakeup boundary (Main review 2026-10-25): with TWO queued
//     rows and an immediately completing provider, the first drain's
//     launched run settles while the lane is mid-await; its terminal
//     coalesces into the pending-wakeup flag and the SAME lane consumes
//     the second row — deterministic, no stranded tail, no duplicate
//     concurrent lane, and a live sibling still defers the drain.
//
//  C05 queue-retirement repair regressions (job-7cb6799042f94ec7,
//  AUTHORED NOT EXECUTED in this lane) close the ACTUAL device defect
//  (entry/C05_QUEUE_RETIREMENT_ACTUAL_FAILURE.json,
//  device/c05-queue-consumption-{settled,later}.xml: the queued 235 user
//  turn persisted BETWEEN the follow-up run's user turn and its final
//  assistant message — a drain launch under a LIVE sibling; the row then
//  restored to `queued` while its text stayed persisted — a post-commit
//  refusal; count 4 and no second reply across fresh dumps — the fast
//  follow-up terminal's coalesced wakeup dropped at the refusal exit).
//  Determinism comes from CONTROLLED gates, never sleeps-as-races:
//  * `WriterHoldGate` occupies the GRDB serial writer with a
//    semaphore-blocked transaction (occupancy PROVEN by an entered signal
//    before use), pinning the drain lane inside its durable claim while
//    actor state and pool reads stay observable — the sibling therefore
//    provably registers BEFORE the lane reaches its launch boundary.
//  * `TestSecretGateway.failReadsAfter` (test-support, additive, default
//    nil) is a read-count gate that lands the start pipeline's step-8
//    `serviceAssemblyFailed` refusal AFTER the atomic prepare committed,
//    while the step-4 admission resolve still succeeds — the exact
//    post-prepare landing, with no fallback branch able to satisfy the
//    assertions (receipt must name a durable FAILED run; provider never
//    reached; exactly one user turn bound to that run).

import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloePersistence
import FloeAgentRuntime
import FloeSecurity
@testable import FloeAndroidCore

final class RuntimeFacadeQueueDrainTests: XCTestCase {
    private var fixture: RunDomainFixture!

    override func setUp() async throws {
        fixture = try await RunDomainFixture.make()
    }

    override func tearDown() async throws {
        RunDomainFacade.uninstall()
        await fixture?.tearDown()
        fixture = nil
    }

    // MARK: - helpers

    private func enqueueRow(conversationID: UUID,
                            content: String,
                            selectedModelID: UUID? = nil,
                            executionMode: String = "agent",
                            attachments: [AttachmentRef] = []) async throws
        -> PendingUserInput {
        try await fixture.inputStore.enqueue(PendingUserInput(
            conversationID: conversationID,
            targetRunID: nil,
            content: content,
            mode: .queue,
            attachments: attachments,
            selectedModelID: selectedModelID,
            executionMode: executionMode))
    }

    private func editEnvelope(conversationID: UUID, row: PendingUserInput,
                              content: String, expectedVersion: String,
                              revisionResource: String? = nil,
                              correlation: String) -> RunCommandEnvelope {
        fixture.executionEnvelope(
            command: "run.input.edit",
            conversationID: conversationID,
            runID: UUID(),   // identity-only scope: the durable lane never
                             // requires run liveness (an idle conversation
                             // must be able to edit its queued rows)
            payload: [
                "inputID": row.id.uuidString,
                "content": content,
                "expectedInputVersion": expectedVersion,
            ],
            correlation: correlation,
            revision: [
                "resourceID": revisionResource
                    ?? RunWireRevision.pendingInputResourceID(row.id),
                "version": expectedVersion,
            ])
    }

    /// Launches one ordinary run and waits for its REAL durable terminal
    /// (the default fixture script completes immediately with endTurn).
    @discardableResult
    private func startAndCompleteRun(_ domain: FacadeRunDomain,
                                     conversationID: UUID,
                                     goal: String,
                                     correlation: String) async throws -> UUID {
        let revision = try await fixture.revision(conversationID: conversationID)
        let envelope = fixture.launchEnvelope(
            conversationID: conversationID,
            payload: fixture.startPayload(goal: goal),
            revisionVersion: revision,
            correlation: correlation)
        let receipt = "op:v1:" + String(repeating: "9", count: 31) + "1"
        let reply = await domain.start(envelope: envelope, receipt: receipt,
                                       correlation: correlation)
        guard case .mutationAccepted(let detail) = reply.outcome,
              let runID = UUID(uuidString: detail["runID"] ?? "") else {
            throw NSError(domain: "fixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(reply.outcome)"])
        }
        let terminal = await waitDurableTerminal(fixture: fixture, runID: runID)
        XCTAssertEqual(terminal, "completed")
        return runID
    }

    private func fixtureAttachment() -> AttachmentRef {
        AttachmentRef(
            id: UUID(),
            conversationID: nil,   // queue-time resolve leaves the binding
                                   // to the launch prepare (original rule)
            messageID: nil,
            kind: .document,
            displayName: "fixture-doc",
            uti: "public.data",
            byteCount: 8,
            sha256: String(repeating: "0", count: 64),
            storage: .applicationSupport,
            urlBookmark: nil,
            relativePath: "attachments/fixture-doc",
            createdAt: Date())
    }

    // MARK: - 1. durable edit/remove envelope grammar

    func testDurableInputEditAcceptsPendingInputRowRevision() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let row = try await enqueueRow(conversationID: conversationID,
                                       content: "original body")
        let version = RunWireRevision.inputVersion(updatedAt: row.updatedAt)
        let reply = await domain.inputEdit(envelope: editEnvelope(
            conversationID: conversationID, row: row,
            content: "edited body", expectedVersion: version,
            correlation: "corr-edit-ok"))
        guard case .mutationAccepted = reply.outcome else {
            return XCTFail("row-revision envelope must be accepted, got \(reply.outcome)")
        }
        let stored = try unwrapAsync(await fixture.inputStore.input(id: row.id))
        XCTAssertEqual(stored.content, "edited body")
        XCTAssertEqual(stored.status, .queued)
        // The CAS version really moved (a fresh detail read is forced on
        // reopen — the projection drops the cached body on a version move).
        XCTAssertNotEqual(RunWireRevision.inputVersion(updatedAt: stored.updatedAt),
                          version)
    }

    func testDurableInputEditRefusesStaleVersionAndPreservesOriginal() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let row = try await enqueueRow(conversationID: conversationID,
                                       content: "original body")
        let reply = await domain.inputEdit(envelope: editEnvelope(
            conversationID: conversationID, row: row,
            content: "edited body",
            expectedVersion: "2001-01-01T00:00:00.000Z",
            correlation: "corr-edit-stale"))
        guard case .rejected = reply.outcome else {
            return XCTFail("a stale row version must be refused, got \(reply.outcome)")
        }
        let stored = try unwrapAsync(await fixture.inputStore.input(id: row.id))
        XCTAssertEqual(stored.content, "original body",
                       "a refused edit must never touch the durable original")
        XCTAssertEqual(stored.status, .queued)
    }

    func testDurableInputEditRefusesConversationResourceEnvelope() async throws {
        // The OLD App grammar (conversation-row digest) must be refused by
        // the row CAS — this is the exact envelope that made every durable
        // Save a silent no-op before the repair.
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let row = try await enqueueRow(conversationID: conversationID,
                                       content: "original body")
        let version = RunWireRevision.inputVersion(updatedAt: row.updatedAt)
        let reply = await domain.inputEdit(envelope: editEnvelope(
            conversationID: conversationID, row: row,
            content: "edited body", expectedVersion: version,
            revisionResource: ConversationRowRevision.resourceID(
                conversationID: conversationID),
            correlation: "corr-edit-oldgrammar"))
        guard case .rejected = reply.outcome else {
            return XCTFail("a conversation-resource envelope must not satisfy the row CAS")
        }
        let stored = try unwrapAsync(await fixture.inputStore.input(id: row.id))
        XCTAssertEqual(stored.content, "original body")
    }

    func testDurableInputRemoveAcceptsPendingInputRowRevision() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let row = try await enqueueRow(conversationID: conversationID,
                                       content: "original body")
        let version = RunWireRevision.inputVersion(updatedAt: row.updatedAt)
        let envelope = fixture.executionEnvelope(
            command: "run.input.remove",
            conversationID: conversationID,
            runID: UUID(),
            payload: ["inputID": row.id.uuidString,
                      "expectedInputVersion": version],
            correlation: "corr-remove-ok",
            revision: ["resourceID": RunWireRevision.pendingInputResourceID(row.id),
                       "version": version])
        let reply = await domain.inputRemove(envelope: envelope)
        guard case .mutationAccepted = reply.outcome else {
            return XCTFail("row-revision remove must be accepted, got \(reply.outcome)")
        }
        let stored = try unwrapAsync(await fixture.inputStore.input(id: row.id))
        XCTAssertEqual(stored.status, .cancelled)
        // The row left the pending predicate (projection retirement then
        // follows the integrated two-complete-page rule).
        let pending = try await fixture.inputStore.pending(conversationID: conversationID)
        XCTAssertFalse(pending.contains { $0.id == row.id })
    }

    // MARK: - 2. run.queue executionMode grammar

    func testQueuePersistsRealExecutionModeAndKeepsAgentDefault() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let digest = try await fixture.revision(conversationID: conversationID)
        let revision = ["resourceID": ConversationRowRevision.resourceID(
                            conversationID: conversationID),
                        "version": digest]
        // Explicit plan mode rides the additive grammar.
        let planReply = await domain.queue(envelope: fixture.executionEnvelope(
            command: "run.queue", conversationID: conversationID, runID: UUID(),
            payload: ["content": "plan follow-up", "mode": "queue",
                      "executionMode": "plan"],
            correlation: "corr-queue-plan", revision: revision))
        guard case .mutationAccepted(let planDetail) = planReply.outcome,
              let planID = UUID(uuidString: planDetail["inputID"] ?? "") else {
            return XCTFail("plan-mode queue must be accepted, got \(planReply.outcome)")
        }
        let planRow = try unwrapAsync(await fixture.inputStore.input(id: planID))
        XCTAssertEqual(planRow.executionMode, "plan")
        // An absent key keeps the historical default (old envelopes unchanged).
        let digest2 = try await fixture.revision(conversationID: conversationID)
        let defaultReply = await domain.queue(envelope: fixture.executionEnvelope(
            command: "run.queue", conversationID: conversationID, runID: UUID(),
            payload: ["content": "agent follow-up", "mode": "queue"],
            correlation: "corr-queue-default",
            revision: ["resourceID": ConversationRowRevision.resourceID(
                           conversationID: conversationID),
                       "version": digest2]))
        guard case .mutationAccepted(let defaultDetail) = defaultReply.outcome,
              let defaultID = UUID(uuidString: defaultDetail["inputID"] ?? "") else {
            return XCTFail("default queue must be accepted, got \(defaultReply.outcome)")
        }
        let defaultRow = try unwrapAsync(await fixture.inputStore.input(id: defaultID))
        XCTAssertEqual(defaultRow.executionMode, "agent")
        // A foreign mode is a typed refusal, never a guessed default.
        let digest3 = try await fixture.revision(conversationID: conversationID)
        let badReply = await domain.queue(envelope: fixture.executionEnvelope(
            command: "run.queue", conversationID: conversationID, runID: UUID(),
            payload: ["content": "bad mode", "mode": "queue",
                      "executionMode": "rm -rf"],
            correlation: "corr-queue-bad",
            revision: ["resourceID": ConversationRowRevision.resourceID(
                           conversationID: conversationID),
                       "version": digest3]))
        guard case .rejected = badReply.outcome else {
            return XCTFail("a foreign executionMode must be refused")
        }
        // The drain mapping is the App's own vocabulary (AGENT travels the
        // chat spelling; plan/goal map to themselves; anything else refuses).
        XCTAssertEqual(FacadeRunDomain.queuedLaunchMode("agent"), .chat)
        XCTAssertEqual(FacadeRunDomain.queuedLaunchMode("chat"), .chat)
        XCTAssertEqual(FacadeRunDomain.queuedLaunchMode("plan"), .plan)
        XCTAssertEqual(FacadeRunDomain.queuedLaunchMode("goal"), .goal)
        XCTAssertNil(FacadeRunDomain.queuedLaunchMode("browserHandoff"))
        XCTAssertNil(FacadeRunDomain.queuedLaunchMode(""))
    }

    // MARK: - 3. terminal queued-input drain (full row ownership)

    func testCompletedTerminalDrainsQueuedRowIntoNewRun() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let row = try await enqueueRow(conversationID: conversationID,
                                       content: "queued follow-up",
                                       selectedModelID: fixture.modelID)
        let firstRun = try await startAndCompleteRun(
            domain, conversationID: conversationID,
            goal: "first turn", correlation: "corr-drain-first")
        // The drain is owned async work dispatched at the real terminal:
        // poll for the durable exactly-once receipt.
        let consumed = await pollFor(timeoutSeconds: 12) {
            let current = try? await self.fixture.inputStore.input(id: row.id)
            return current?.status == .consumed && current?.consumedRunID != nil
        }
        XCTAssertTrue(consumed, "the completed terminal must consume the queued row")
        let stored = try unwrapAsync(await fixture.inputStore.input(id: row.id))
        let launchedRunID = try unwrapAsync(stored.consumedRunID)
        XCTAssertNotEqual(launchedRunID, firstRun,
                          "the receipt names the NEW run, never the finished one")
        let launched = try unwrapAsync(await fixture.runStore.run(id: launchedRunID))
        XCTAssertEqual(launched.conversationID, conversationID)
        // The follow-up launch really reached the provider (second request).
        let secondRequest = await pollFor(timeoutSeconds: 12) {
            self.fixture.adapter.requestCount >= 2
        }
        XCTAssertTrue(secondRequest, "the queued body must launch a real run")
        // The launched run's durable user turn carries the queued content.
        let messages = try await fixture.conversationStore.messages(
            conversationID: conversationID)
        XCTAssertTrue(messages.contains {
            $0.role == "user" && $0.content == "queued follow-up" &&
                $0.runID == launchedRunID
        }, "the queued body must become the new run's user turn")
    }

    func testDrainLaunchesAttachmentRowThroughTrustedSeam() async throws {
        // FULL ownership: an attachment-bearing row is launched WITH its
        // resolved durable attachments (never text-only, never stranded).
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let attachment = fixtureAttachment()
        let row = try await enqueueRow(conversationID: conversationID,
                                       content: "queued with attachment",
                                       selectedModelID: fixture.modelID,
                                       attachments: [attachment])
        try await startAndCompleteRun(domain, conversationID: conversationID,
                                      goal: "first turn", correlation: "corr-drain-att")
        let consumed = await pollFor(timeoutSeconds: 12) {
            let current = try? await self.fixture.inputStore.input(id: row.id)
            return current?.status == .consumed && current?.consumedRunID != nil
        }
        XCTAssertTrue(consumed, "an attachment row must launch, not strand")
        let stored = try unwrapAsync(await fixture.inputStore.input(id: row.id))
        let launchedRunID = try unwrapAsync(stored.consumedRunID)
        // The ORIGINAL atomic prepare bound the durable ref to the new
        // run's user message (real attachment part, not a dropped ref).
        let bound = await pollFor(timeoutSeconds: 12) {
            let messages = try? await self.fixture.conversationStore.messages(
                conversationID: conversationID)
            return messages?.contains { message in
                message.role == "user" && message.runID == launchedRunID &&
                    message.content == "queued with attachment" &&
                    message.parts.contains { $0.attachmentID == attachment.id }
            } == true
        }
        XCTAssertTrue(bound, "the launched user turn must carry the row's attachment part")
    }

    func testDrainRefusesUnresolvableExplicitModelWithoutDefaultFallback() async throws {
        // iOS providerAndModel parity: an EXPLICIT selection that no longer
        // resolves REFUSES (row restored, visibly queued) — it never
        // silently launches on the persisted default. A SECOND disabled
        // model carries the row selection so the trigger run's own launch
        // route (the enabled fixture model) stays valid and deterministic.
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        var disabledModel = fixture.modelProfile
        disabledModel.id = UUID()
        disabledModel.remoteModelID = "fixture-model-disabled"
        disabledModel.displayName = "Fixture Disabled"
        disabledModel.isEnabled = false
        try await fixture.modelStore.saveModel(disabledModel)
        let row = try await enqueueRow(conversationID: conversationID,
                                       content: "queued without route",
                                       selectedModelID: disabledModel.id)
        try await startAndCompleteRun(domain, conversationID: conversationID,
                                      goal: "first turn", correlation: "corr-drain-route")
        let restored = await pollFor(timeoutSeconds: 12) {
            let current = try? await self.fixture.inputStore.input(id: row.id)
            return current?.status == .queued
        }
        XCTAssertTrue(restored, "an unroutable explicit selection must restore the row")
        let stored = try unwrapAsync(await fixture.inputStore.input(id: row.id))
        XCTAssertEqual(stored.content, "queued without route")
        XCTAssertEqual(stored.selectedModelID, disabledModel.id)
        let pending = try await fixture.inputStore.pending(conversationID: conversationID)
        XCTAssertTrue(pending.contains { $0.id == row.id },
                      "the refused row stays visibly queued")
        // And no follow-up run was launched for the refused row.
        XCTAssertEqual(fixture.adapter.requestCount, 1,
                       "a refused route must not launch")
    }

    // MARK: - 4. lost-wakeup boundary + sibling deferral

    func testFastTerminalCoalescesWakeupAndDrainsSecondRow() async throws {
        // DETERMINISTIC lost-wakeup boundary (Main review 2026-10-25):
        // TWO queued rows + an immediately completing provider. Row 1's
        // launched run settles while the lane is still inside
        // start/markConsumed; its terminal finds the lane busy and must
        // COALESCE (pending-wakeup flag), and the SAME lane must then
        // consume row 2 — no stranded tail, no second concurrent lane, no
        // duplicate launch.
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let row1 = try await enqueueRow(conversationID: conversationID,
                                        content: "first queued",
                                        selectedModelID: fixture.modelID)
        let row2 = try await enqueueRow(conversationID: conversationID,
                                        content: "second queued",
                                        selectedModelID: fixture.modelID)
        try await startAndCompleteRun(domain, conversationID: conversationID,
                                      goal: "trigger turn", correlation: "corr-coalesce")
        let bothConsumed = await pollFor(timeoutSeconds: 20) {
            let first = try? await self.fixture.inputStore.input(id: row1.id)
            let second = try? await self.fixture.inputStore.input(id: row2.id)
            return first?.status == .consumed && first?.consumedRunID != nil &&
                second?.status == .consumed && second?.consumedRunID != nil
        }
        XCTAssertTrue(bothConsumed,
                      "both rows must consume — a coalesced wakeup may never strand row 2")
        let stored1 = try unwrapAsync(await fixture.inputStore.input(id: row1.id))
        let stored2 = try unwrapAsync(await fixture.inputStore.input(id: row2.id))
        let run1 = try unwrapAsync(stored1.consumedRunID)
        let run2 = try unwrapAsync(stored2.consumedRunID)
        XCTAssertNotEqual(run1, run2, "each row receipts its OWN launched run")
        // Strict queue order: row 1's run started before row 2's.
        let record1 = try unwrapAsync(await fixture.runStore.run(id: run1))
        let record2 = try unwrapAsync(await fixture.runStore.run(id: run2))
        XCTAssertLessThanOrEqual(record1.startedAt, record2.startedAt)
        // The queue is really empty (no stranded pending tail).
        let pending = try await fixture.inputStore.pending(conversationID: conversationID)
        XCTAssertTrue(pending.isEmpty, "no row may remain pending after the chain")
        // Both follow-ups really reached the provider (trigger + 2 launches).
        let requests = await pollFor(timeoutSeconds: 12) {
            self.fixture.adapter.requestCount >= 3
        }
        XCTAssertTrue(requests, "both consumed rows must launch real runs")
    }

    func testDrainSkipsWhileSiblingRunStillLive() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let row = try await enqueueRow(conversationID: conversationID,
                                       content: "queued follow-up",
                                       selectedModelID: fixture.modelID)
        // Run A stalls at the gate; run B completes. B's terminal must NOT
        // drain while A is live (iOS: every service terminal is required).
        let gate = RunGateBox()
        let stallIndex = fixture.adapter.requestCount
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "held")),
            .completed(.init(stopReason: .endTurn)),
        ], stallAfter: 1, gate: gate), forRequest: stallIndex)
        let runA = try await startRunLive(domain, conversationID: conversationID,
                                          goal: "stalled A", correlation: "corr-drain-a")
        let parked = await pollFor(timeoutSeconds: 8) { gate.isWaiting }
        XCTAssertTrue(parked, "run A must really park at the gate")
        let runB = try await startAndCompleteRun(
            domain, conversationID: conversationID,
            goal: "completing B", correlation: "corr-drain-b")
        XCTAssertNotEqual(runA, runB)
        let stayedQueued = await pollFor(timeoutSeconds: 4) {
            let current = try? await self.fixture.inputStore.input(id: row.id)
            return current?.status == .queued
        }
        XCTAssertTrue(stayedQueued, "a live sibling run must defer the drain")
        // Releasing A completes it; A's own terminal then drains the row.
        gate.release()
        let consumed = await pollFor(timeoutSeconds: 15) {
            let current = try? await self.fixture.inputStore.input(id: row.id)
            return current?.status == .consumed && current?.consumedRunID != nil
        }
        XCTAssertTrue(consumed, "the LAST live run's terminal must drain the queue")
    }

    /// Starts a run and waits only until it is REALLY owned/live, leaving
    /// it running for sibling-guard assertions.
    private func startRunLive(_ domain: FacadeRunDomain,
                              conversationID: UUID,
                              goal: String,
                              correlation: String) async throws -> UUID {
        let revision = try await fixture.revision(conversationID: conversationID)
        let envelope = fixture.launchEnvelope(
            conversationID: conversationID,
            payload: fixture.startPayload(goal: goal),
            revisionVersion: revision,
            correlation: correlation)
        let receipt = "op:v1:" + String(repeating: "9", count: 31) + "2"
        let reply = await domain.start(envelope: envelope, receipt: receipt,
                                       correlation: correlation)
        guard case .mutationAccepted(let detail) = reply.outcome,
              let runID = UUID(uuidString: detail["runID"] ?? "") else {
            throw NSError(domain: "fixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(reply.outcome)"])
        }
        let live = await pollFor(timeoutSeconds: 8) {
            await domain.ownership(runID: runID) != nil
        }
        XCTAssertTrue(live, "run \(runID) must be owned/live")
        return runID
    }

    // MARK: - C05 queue-retirement repair regressions

    func testDrainDefersWhileSiblingLiveAtLaunchBoundaryAndDrainsAtItsTerminal() async throws {
        // Deterministic device shape: the drain lane is dispatched (the
        // production entry a real terminal calls) while the writer gate
        // pins its durable claim; a sibling ordinary run then registers
        // ownership (registration precedes ANY DB op, so it is provably
        // live while the lane is mid-await). On release, the fixed lane
        // must re-prove sibling liveness AT THE LAUNCH BOUNDARY and defer
        // with ZERO durable user effect; the dispatch-only guard instead
        // launches a second run under the live sibling. The sibling's own
        // real terminal must then drain the row exactly once, in strict
        // order (no overlap, no duplicate turn).
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let row = try await enqueueRow(conversationID: conversationID,
                                       content: "queued under sibling",
                                       selectedModelID: fixture.modelID)
        let revision = try await fixture.revision(conversationID: conversationID)
        let gate = RunGateBox()
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "held sibling")),
            .completed(.init(stopReason: .endTurn)),
        ], stallAfter: 1, gate: gate), forRequest: fixture.adapter.requestCount)
        let writerGate = WriterHoldGate()
        defer { writerGate.releaseWriter() }
        writerGate.hold(fixture.database)
        await domain.dispatchQueuedInputDrain(conversationID: conversationID,
                                              bundle: domain.durable)
        let laneActive = await domain.queueDrainActive.contains(conversationID)
        XCTAssertTrue(laneActive, "the lane must be active, pinned at its durable claim")
        // Start the sibling WITHOUT awaiting completion (its prepare
        // queues behind the writer gate); ownership registration happens
        // before its first DB op.
        let siblingEnvelope = fixture.launchEnvelope(
            conversationID: conversationID,
            payload: fixture.startPayload(goal: "sibling probe"),
            revisionVersion: revision,
            correlation: "corr-c05a-sibling")
        let siblingTask = Task { [domain] in
            _ = await domain.start(envelope: siblingEnvelope,
                                   receipt: "op:v1:" + String(repeating: "9", count: 31) + "3",
                                   correlation: "corr-c05a-sibling")
        }
        let siblingLive = await pollFor(timeoutSeconds: 8) {
            await domain.owners(conversationID: conversationID).count >= 1
        }
        XCTAssertTrue(siblingLive,
                      "the sibling must register ownership while the writer gate is held")
        let siblingOwners = await domain.owners(conversationID: conversationID)
        let siblingID = try XCTUnwrap(siblingOwners.map(\.runID).first)
        // Release: the claim completes and the lane reaches its launch
        // boundary with the sibling PROVABLY live (parks at the provider
        // gate; it cannot retire before the assertions below).
        writerGate.releaseWriter()
        let parked = await pollFor(timeoutSeconds: 10) { gate.isWaiting }
        XCTAssertTrue(parked, "the sibling must really park at the provider gate")
        // DEFERRAL WINDOW: while the sibling is live, the row must be back
        // to `queued` with ZERO durable user effect, and only the sibling
        // may have reached the provider.
        let deferred = await pollFor(timeoutSeconds: 10) {
            let current = try? await self.fixture.inputStore.input(id: row.id)
            guard current?.status == .queued else { return false }
            let messages = try? await self.fixture.conversationStore.messages(
                conversationID: conversationID)
            return messages?.contains {
                $0.role == "user" && $0.content == "queued under sibling"
            } != true
        }
        XCTAssertTrue(deferred,
            "C05 defect: the lane launched under the live sibling (row consumed or its user turn persisted while the sibling was parked)")
        XCTAssertEqual(fixture.adapter.requestCount, 1,
                       "only the sibling may reach the provider during the deferral window")
        // The sibling's OWN real terminal must now drain the row exactly
        // once — the observed completion path.
        gate.release()
        _ = await siblingTask.value
        let siblingState = await waitDurableTerminal(fixture: fixture, runID: siblingID)
        XCTAssertEqual(siblingState, "completed")
        let consumed = await pollFor(timeoutSeconds: 15) {
            let current = try? await self.fixture.inputStore.input(id: row.id)
            return current?.status == .consumed && current?.consumedRunID != nil
        }
        XCTAssertTrue(consumed, "the sibling's terminal must drain the deferred row")
        let stored = try unwrapAsync(await fixture.inputStore.input(id: row.id))
        let drainedRunID = try unwrapAsync(stored.consumedRunID)
        XCTAssertNotEqual(drainedRunID, siblingID, "the receipt names the NEW run")
        let drained = try unwrapAsync(await fixture.runStore.run(id: drainedRunID))
        let siblingRecord = try unwrapAsync(await fixture.runStore.run(id: siblingID))
        let siblingEnd = try XCTUnwrap(siblingRecord.endedAt,
                                       "the sibling's terminal must be durable")
        XCTAssertGreaterThanOrEqual(drained.startedAt, siblingEnd,
            "strict order: the drain never overlaps the sibling's live window")
        let messages = try await fixture.conversationStore.messages(
            conversationID: conversationID)
        let turns = messages.filter {
            $0.role == "user" && $0.content == "queued under sibling"
        }
        XCTAssertEqual(turns.count, 1,
                       "exactly ONE durable user turn for the row — never duplicated")
        XCTAssertEqual(turns.first?.runID, drainedRunID,
                       "the single turn belongs to the drained run")
        let secondRequest = await pollFor(timeoutSeconds: 12) {
            self.fixture.adapter.requestCount >= 2
        }
        XCTAssertTrue(secondRequest, "the drained row must launch a real run")
    }

    func testRefusalExitHonorsParkedWakeupWithRealSecondDispatch() async throws {
        // Deterministic parked-wakeup proof through EXISTING production
        // observables (no new counters): the writer gate pins lane #1
        // inside its durable claim, so the second dispatch — a real
        // terminal arriving mid-await — PROVABLY coalesces into
        // `queueDrainRecheck`. The head row carries a foreign
        // executionMode: lane #1 refuses it (never a guessed mode) and
        // restores it. The fixed exit honors the parked wakeup with exactly
        // ONE bounded re-dispatch, observed through the EXISTING
        // lease-evidence trail (`feedEvidence`: one token per real dispatch
        // attach). Delta 2 = lane #1 + the honored re-dispatch; the buggy
        // drop leaves delta 1; any spin would exceed 2. The re-dispatched
        // lane honestly re-refuses the same head row: bounded, no provider
        // requests, row visibly queued with its original body.
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let row = try await enqueueRow(conversationID: conversationID,
                                       content: "queued foreign mode",
                                       selectedModelID: fixture.modelID,
                                       executionMode: "weirdMode")
        let writerGate = WriterHoldGate()
        defer { writerGate.releaseWriter() }
        writerGate.hold(fixture.database)
        let evidenceBefore = await domain.feedEvidence[conversationID]?.count ?? 0
        await domain.dispatchQueuedInputDrain(conversationID: conversationID,
                                              bundle: domain.durable)
        let laneActive = await domain.queueDrainActive.contains(conversationID)
        XCTAssertTrue(laneActive, "lane #1 must be active, pinned at its claim")
        await domain.dispatchQueuedInputDrain(conversationID: conversationID,
                                              bundle: domain.durable)
        let parkedFlag = await domain.queueDrainRecheck.contains(conversationID)
        XCTAssertTrue(parkedFlag,
            "a terminal arriving while the lane is pinned mid-claim must coalesce into the pending-wakeup flag")
        writerGate.releaseWriter()
        let quiesced = await pollFor(timeoutSeconds: 12) {
            let active = await domain.queueDrainActive.isEmpty
            let stillParked = await domain.queueDrainRecheck.isEmpty
            let current = try? await self.fixture.inputStore.input(id: row.id)
            return active && stillParked && current?.status == .queued
        }
        XCTAssertTrue(quiesced, "both lanes must finish with the row restored and no parked flag left")
        let evidenceAfter = await domain.feedEvidence[conversationID]?.count ?? 0
        XCTAssertEqual(evidenceAfter - evidenceBefore, 2,
            "the parked wakeup must produce exactly ONE real bounded re-dispatch (existing lease-evidence trail): a dropped wakeup leaves 1, a spin leaves more")
        let stored = try unwrapAsync(await fixture.inputStore.input(id: row.id))
        XCTAssertEqual(stored.status, .queued)
        XCTAssertEqual(stored.content, "queued foreign mode",
                       "the refused row keeps its original body byte-intact")
        XCTAssertEqual(fixture.adapter.requestCount, 0,
                       "a refusing head row never reaches the provider, honored re-dispatch included")
        let pending = try await fixture.inputStore.pending(conversationID: conversationID)
        XCTAssertTrue(pending.contains { $0.id == row.id },
                      "the refused row stays visibly queued")
        let proofEmpty = await domain.postCommitRefusedLaunches.isEmpty
        XCTAssertTrue(proofEmpty,
                      "a no-effect refusal must never leave committed-run proof behind")
    }

    func testCommittedAbandonedRefusalRetiresRowUnderRunReceiptNeverRequeues() async throws {
        // Deterministic post-prepare landing through the EXISTING fixture
        // gateway's read-count gate (no sleeps, no races): read #1 is the
        // step-4 admission resolve (succeeds); read #2 is the step-8
        // service-assembly credentials resolve, which fails AFTER the
        // atomic prepare committed the row's user turn — the exact
        // `serviceAssemblyFailed` landing, and the only code path that can
        // produce the observed device state (persisted turn + row restored
        // to `queued`). The fixed lane retires the row under the REAL
        // abandoned run's identity (the durable failed run row is the
        // honest receipt); the buggy lane restores the row and strands
        // persisted content (a duplicate user turn on the next drain).
        // No fallback branch can satisfy these assertions: the receipt
        // must name a durable FAILED run, the provider must never have
        // been reached, and exactly one user turn bound to that run may
        // exist. (Direct dispatch stands in for the real terminal entry;
        // terminal-dispatch coverage stays with the original suite.)
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let row = try await enqueueRow(conversationID: conversationID,
                                       content: "queued under commit",
                                       selectedModelID: fixture.modelID)
        fixture.gateway.failReadsAfter = fixture.gateway.readCount + 1
        defer { fixture.gateway.failReadsAfter = nil }
        await domain.dispatchQueuedInputDrain(conversationID: conversationID,
                                              bundle: domain.durable)
        let settled = await pollFor(timeoutSeconds: 15) {
            // Dispatch marks the lane active synchronously. Wait for its real
            // exit instead of accepting the row's initial queued state.
            let active = await domain.queueDrainActive.contains(conversationID)
            guard !active else { return false }
            let current = try? await self.fixture.inputStore.input(id: row.id)
            return current?.status == .consumed || current?.status == .queued
        }
        XCTAssertTrue(settled, "the lane must reach a durable retirement decision")
        let stored = try unwrapAsync(await fixture.inputStore.input(id: row.id))
        XCTAssertEqual(stored.status, .consumed,
            "C05 defect: a refusal AFTER the durable commit restored the row — the persisted user turn would duplicate on the next drain")
        let receiptRunID = try unwrapAsync(stored.consumedRunID)
        let record = try unwrapAsync(await fixture.runStore.run(id: receiptRunID))
        XCTAssertEqual(record.state, "failed",
                       "the receipt must name the REAL committed-then-abandoned run (durable failed state)")
        XCTAssertEqual(fixture.adapter.requestCount, 0,
                       "the abandoned launch never reached the provider — a successful launch is NOT the target landing")
        let messages = try await fixture.conversationStore.messages(
            conversationID: conversationID)
        let turns = messages.filter {
            $0.role == "user" && $0.content == "queued under commit"
        }
        XCTAssertEqual(turns.count, 1, "exactly ONE durable user turn for the row")
        XCTAssertEqual(turns.first?.runID, receiptRunID,
                       "the persisted turn belongs to the receipt's abandoned run")
        let pending = try await fixture.inputStore.pending(conversationID: conversationID)
        XCTAssertFalse(pending.contains { $0.id == row.id },
                       "the retired row must leave the visible queue")
        let proofEmpty = await domain.postCommitRefusedLaunches.isEmpty
        XCTAssertTrue(proofEmpty,
                      "the committed-run proof is consumed exactly once by the lane")
    }

    // MARK: - 7. C09 queue-settle publication + causal observer regressions
    //
    // Contract §7 N1–N9 (job-4822f733addf4f0b design, MAIN_ADDENDUM A–F
    // corrections). AUTHORED, NOT EXECUTED in this lane; determinism comes
    // from the same CONTROLLED gates as sections above (WriterHoldGate,
    // provider script gates, synthetic saved anchors) — never sleeps-as-races
    // — plus STATS/FACT DELTA assertions where the coalesced-wakeup race can
    // legitimately add ONE further honest publication (documented per test).

    /// A durable COMPLETED run row written directly to the store: a real
    /// anchor whose journal accepts the settle fact and whose window
    /// materializes `attached`, WITHOUT any provider traffic. Used where the
    /// contract's N-shape needs an anchor that retired earlier in history
    /// (the direct-dispatch idiom already stands in for the terminal entry).
    @discardableResult
    private func makeSyntheticTerminalRun(conversationID: UUID,
                                          goal: String) async throws -> UUID {
        let runID = UUID()
        let now = Date()
        try await fixture.runStore.saveRun(RunRecord(
            id: runID, conversationID: conversationID, state: "completed",
            goal: goal, startedAt: now.addingTimeInterval(-60),
            endedAt: now))
        return runID
    }

    /// Decode ONLY the stateless `queueSettled` invalidation facts on a
    /// journal (the vocabulary word filters every other status frame).
    private func settleFacts(runID: UUID) async throws
        -> [(sequence: Int, payload: [String: Any])] {
        let events = try await fixture.runStore.events(runID: runID)
        return events.filter { $0.kind == .notice }.compactMap { record in
            guard let data = record.payloadJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  (object["reason"] as? String) == FacadeRunDomain.queueSettleReason
            else { return nil }
            return (record.sequence, object)
        }
    }

    private func pollSettledQuiescence(_ domain: FacadeRunDomain,
                                       conversationID: UUID,
                                       timeoutSeconds: Double = 15) async {
        let quiesced = await pollFor(timeoutSeconds: timeoutSeconds) {
            let active = await domain.queueDrainActive.isEmpty
            let recheck = await domain.queueDrainRecheck.isEmpty
            let duties = await domain.queueDrainDuties.isEmpty
            let leases = await domain.queueDrainLeases[conversationID] == nil
            return active && recheck && duties && leases
        }
        XCTAssertTrue(quiesced, "all drain lanes must reach their honest exit")
    }

    func testDrainExitPublishesSettleFactOnAnchorJournalAndWindow() async throws {
        // N1: REAL terminal production path. The launched follow-up is
        // SCRIPT-STALLS at the provider (gate), so exactly one lane exit
        // happens before any second terminal can exist: the fact on the
        // trigger anchor is deterministically lane=consumed chain=closed.
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let row = try await enqueueRow(conversationID: conversationID,
                                       content: "queued follow-up settle",
                                       selectedModelID: fixture.modelID)
        let gate = RunGateBox()
        defer { gate.release() }
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "held follow-up")),
            .completed(.init(stopReason: .endTurn)),
        ], stallAfter: 1, gate: gate), forRequest: fixture.adapter.requestCount + 1)
        let anchor = try await startAndCompleteRun(
            domain, conversationID: conversationID,
            goal: "settle trigger", correlation: "corr-c09-n1")
        let factVisible = await pollFor(timeoutSeconds: 15) {
            let facts = (try? await self.settleFacts(runID: anchor)) ?? []
            return !facts.isEmpty
        }
        XCTAssertTrue(factVisible, "the lane exit must publish under the still-held lease")
        let facts = try await settleFacts(runID: anchor)
        XCTAssertEqual(facts.count, 1, "exactly ONE settle fact on the anchor journal")
        let payload = try XCTUnwrap(facts.first?.payload)
        XCTAssertEqual(payload["reason"] as? String, FacadeRunDomain.queueSettleReason)
        XCTAssertEqual(payload["lane"] as? String, "consumed",
            "the follow-up is gated live, so this exit is the consumed receipt itself")
        XCTAssertEqual(payload["chain"] as? String, "closed",
            "no other terminal parked while this lane ran")
        XCTAssertNil(payload["state"],
            "the settle vocabulary NEVER carries a run-state member (renders nothing)")
        let factSequence = try XCTUnwrap(facts.first?.sequence)
        let page = fixture.events.pollDurable(runID: anchor, afterSequence: 0,
                                              budgetBytes: 65_536)
        XCTAssertEqual(page["windowState"] as? String, "attached",
            "the fact materializes into the pump window the binder serves")
        XCTAssertGreaterThanOrEqual(page["watermark"] as? Int ?? -1, factSequence,
            "the window watermark covers the committed fact")
        // Release the follow-up; the chain settles honestly through its own
        // lane (duty path) before teardown.
        gate.release()
        let consumed = await pollFor(timeoutSeconds: 15) {
            let current = try? await self.fixture.inputStore.input(id: row.id)
            return current?.status == .consumed && current?.consumedRunID != nil
        }
        XCTAssertTrue(consumed)
        await pollSettledQuiescence(domain, conversationID: conversationID)
        XCTAssertEqual(fixture.adapter.requestCount, 2,
            "trigger + the one follow-up launch — no duplicate")
    }

    func testRefusedHeadRowPublishesSettleFactAndStaysVisiblyQueued() async throws {
        // N2: an explicit unroutable row through the REAL terminal path.
        // Single terminal + refusal never launches ⇒ deterministic lane=
        // refused chain=closed; the row keeps its body byte-intact.
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        var disabledModel = fixture.modelProfile
        disabledModel.id = UUID()
        disabledModel.remoteModelID = "fixture-model-c09-disabled"
        disabledModel.displayName = "Fixture Disabled C09"
        disabledModel.isEnabled = false
        try await fixture.modelStore.saveModel(disabledModel)
        let row = try await enqueueRow(conversationID: conversationID,
                                       content: "queued without route settle",
                                       selectedModelID: disabledModel.id)
        let anchor = try await startAndCompleteRun(
            domain, conversationID: conversationID,
            goal: "refusal trigger", correlation: "corr-c09-n2")
        let factVisible = await pollFor(timeoutSeconds: 15) {
            let facts = (try? await self.settleFacts(runID: anchor)) ?? []
            return !facts.isEmpty
        }
        XCTAssertTrue(factVisible)
        let facts = try await settleFacts(runID: anchor)
        XCTAssertEqual(facts.count, 1)
        let payload = try XCTUnwrap(facts.first?.payload)
        XCTAssertEqual(payload["lane"] as? String, "refused",
            "the refusal exit carries the honest lane class")
        XCTAssertEqual(payload["chain"] as? String, "closed",
            "single terminal, refusal launches nothing ⇒ no park possible")
        XCTAssertNil(payload["state"])
        await pollSettledQuiescence(domain, conversationID: conversationID)
        let stored = try unwrapAsync(await fixture.inputStore.input(id: row.id))
        XCTAssertEqual(stored.status, .queued)
        XCTAssertEqual(stored.content, "queued without route settle",
                       "the refused row keeps its original body byte-intact")
        let pending = try await fixture.inputStore.pending(conversationID: conversationID)
        XCTAssertTrue(pending.contains { $0.id == row.id },
                      "a refused row stays visibly queued (the fact renders nothing)")
        XCTAssertEqual(fixture.adapter.requestCount, 1,
                       "a refused route never launches — the fact is the only IO")
    }

    func testOwnedLeaseHeldAcrossSettlePublicationAndReleasedExactlyOnce() async throws {
        // N3 (QREV-01): while the append is gated INSIDE the publish await,
        // the registry still sees the lane's owned work — the delete drain
        // and root shutdown provably BLOCK (waitForDrain false), and the
        // lane's active flag + single lease are still live. After release,
        // the fact materializes, the EXACT token detached last, and the
        // epoch's owned count is back to its pre-dispatch baseline.
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let anchor = try await makeSyntheticTerminalRun(conversationID: conversationID,
                                                        goal: "owned-publication anchor")
        let row = try await enqueueRow(conversationID: conversationID,
                                       content: "owned lease settle row",
                                       selectedModelID: fixture.modelID)
        let gateStore = GatedPublishRunStore(wrapped: fixture.runStore, gatedAnchor: anchor)
        defer { gateStore.releaseAppend() }
        let bundle = RunPersistenceBundle(identity: .ordinary,
                                          conversations: fixture.conversationStore,
                                          runs: gateStore,
                                          runningInputs: fixture.inputStore,
                                          launches: fixture.launchStore,
                                          childRuns: fixture.childStore,
                                          intelligence: fixture.intelligence)
        let baseline = await RuntimeOwnedWorkRegistry.shared.count(for: fixture.epoch)
        await domain.dispatchQueuedInputDrain(conversationID: conversationID,
                                              bundle: bundle,
                                              anchorRunID: anchor)
        let entered = gateStore.awaitEntered(timeoutSeconds: 15)
        XCTAssertTrue(entered,
            "the settle publication must reach its append INSIDE the still-held lane lease")
        // Publication IO is in flight UNDER the lease:
        let stillActive = await domain.queueDrainActive.contains(conversationID)
        XCTAssertTrue(stillActive, "the lane must stay ACTIVE across the publish await")
        let leaseCount = await domain.queueDrainLeases[conversationID]?.count ?? 0
        XCTAssertEqual(leaseCount, 1, "the lane's exact lease is still held")
        let live = await RuntimeOwnedWorkRegistry.shared.count(for: fixture.epoch)
        XCTAssertGreaterThanOrEqual(live, baseline + 1,
            "the publication is REAL owned work the shutdown must wait for")
        let drainedEarly = await RuntimeOwnedWorkRegistry.shared.waitForDrain(
            epoch: fixture.epoch, timeoutMillis: 300)
        XCTAssertFalse(drainedEarly,
            "delete drain / root shutdown must NOT see zero while publication IO owns the lease")
        gateStore.releaseAppend()
        let settled = await pollFor(timeoutSeconds: 15) {
            let page = self.fixture.events.pollDurable(runID: anchor, afterSequence: 0,
                                                       budgetBytes: 65_536)
            let facts = (try? await self.settleFacts(runID: anchor)) ?? []
            guard let sequence = facts.first?.sequence else { return false }
            let active = await domain.queueDrainActive.isEmpty
            let leases = await domain.queueDrainLeases[conversationID] == nil
            let count = await RuntimeOwnedWorkRegistry.shared.count(for: self.fixture.epoch)
            return (page["windowState"] as? String) == "attached"
                && (page["watermark"] as? Int ?? -1) >= sequence
                && active && leases && count == baseline
        }
        XCTAssertTrue(settled,
            "the fact materializes, the exact token detached LAST, and owned work returns to baseline")
        let consumed = await pollFor(timeoutSeconds: 15) {
            let current = try? await self.fixture.inputStore.input(id: row.id)
            return current?.status == .consumed && current?.consumedRunID != nil
        }
        XCTAssertTrue(consumed)
        await pollSettledQuiescence(domain, conversationID: conversationID)
    }

    func testAppendFailureIsTypedObservableAndPreservesConsumption() async throws {
        // N4 (QREV-03 + MAIN_ADDENDUM F): the auxiliary append throws ⇒
        // IMMEDIATE typed degrade — no journal retry, NO business
        // re-creation. Consumption/receipt are untouched; the host-visible
        // signal is the EXISTING resyncRequired member on the anchor poll.
        // The follow-up's own duty publication (coalesced B shape) lands a
        // second fact on the follow-up run, so stats are asserted as
        // exact PER-ANCHOR deltas, not absolute totals.
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let anchorA1 = try await makeSyntheticTerminalRun(conversationID: conversationID,
                                                          goal: "append-fail anchor")
        let row = try await enqueueRow(conversationID: conversationID,
                                       content: "append fail settle row",
                                       selectedModelID: fixture.modelID)
        let failing = FailingAppendRunStore(wrapped: fixture.runStore, failingAnchor: anchorA1)
        let bundle = RunPersistenceBundle(identity: .ordinary,
                                          conversations: fixture.conversationStore,
                                          runs: failing,
                                          runningInputs: fixture.inputStore,
                                          launches: fixture.launchStore,
                                          childRuns: fixture.childStore,
                                          intelligence: fixture.intelligence)
        let statsBefore = await domain.queueSettleStats
        await domain.dispatchQueuedInputDrain(conversationID: conversationID,
                                              bundle: bundle,
                                              anchorRunID: anchorA1)
        await pollSettledQuiescence(domain, conversationID: conversationID)
        let statsAfter = await domain.queueSettleStats
        XCTAssertEqual(statsAfter.appendFailed - statsBefore.appendFailed, 1,
            "the append throw is counted exactly once for this anchor (degrade-immediate, no retry)")
        let stored = try unwrapAsync(await fixture.inputStore.input(id: row.id))
        XCTAssertEqual(stored.status, .consumed)
        XCTAssertNotNil(stored.consumedRunID,
            "publication failure NEVER touches the consumption row/receipt")
        let anchorFacts = try await settleFacts(runID: anchorA1)
        XCTAssertTrue(anchorFacts.isEmpty, "the failed append left NO fact on the anchor")
        let degradedA1 = await fixture.events.isSettlePublicationDegraded(runID: anchorA1)
        XCTAssertTrue(degradedA1)
        let page = fixture.events.pollDurable(runID: anchorA1, afterSequence: 0,
                                              budgetBytes: 65_536)
        XCTAssertEqual(page["windowState"] as? String, "notAttached")
        XCTAssertEqual(page["resyncRequired"] as? Bool, true,
            "the host-visible signal rides the EXISTING wire member, no new schema")
        let leasesCleared = await domain.queueDrainLeases[conversationID] == nil
        XCTAssertTrue(leasesCleared)
        // Recovery: the NEXT real chain publishes its own anchor's fact
        // through a healthy bundle and reads back clean.
        let anchorA2 = try await makeSyntheticTerminalRun(conversationID: conversationID,
                                                          goal: "recovery anchor")
        let row2 = try await enqueueRow(conversationID: conversationID,
                                        content: "recovery settle row",
                                        selectedModelID: fixture.modelID)
        await domain.dispatchQueuedInputDrain(conversationID: conversationID,
                                              bundle: domain.durable,
                                              anchorRunID: anchorA2)
        await pollSettledQuiescence(domain, conversationID: conversationID)
        let recoveryFacts = try await settleFacts(runID: anchorA2)
        XCTAssertFalse(recoveryFacts.isEmpty,
            "a healthy chain publishes where the host's CURRENT watch reads")
        let publishedAfter = await domain.queueSettleStats.published
        XCTAssertGreaterThan(publishedAfter, statsAfter.published,
            "the recovery publication is counted (delta ≥ 1 incl. the follow-up duty fact)")
        let degradedA2 = await fixture.events.isSettlePublicationDegraded(runID: anchorA2)
        XCTAssertFalse(degradedA2, "the recovery anchor's window is verified clean")
        let consumed2 = await pollFor(timeoutSeconds: 15) {
            let current = try? await self.fixture.inputStore.input(id: row2.id)
            return current?.status == .consumed && current?.consumedRunID != nil
        }
        XCTAssertTrue(consumed2)
    }

    func testValidMultiPageBacklogMaterializesWithoutFailureClassification() async throws {
        // N5 (Main's backlog steer): 450 un-refreshed journal events are a
        // VALID >one-page backlog, NOT an IO failure. The progress-driven
        // loop pages through (200/200/remaining) and the fact materializes
        // with ZERO windowUnmaterialized classification.
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let anchor = try await makeSyntheticTerminalRun(conversationID: conversationID,
                                                        goal: "backlog anchor")
        for index in 1...450 {
            _ = try await fixture.runStore.appendEvent(
                runID: anchor, kind: .status,
                payloadJSON: "{\"filler\":\(index)}")
        }
        let row = try await enqueueRow(conversationID: conversationID,
                                       content: "backlog settle row",
                                       selectedModelID: fixture.modelID)
        let before = await domain.queueSettleStats
        await domain.dispatchQueuedInputDrain(conversationID: conversationID,
                                              bundle: domain.durable,
                                              anchorRunID: anchor)
        let facts = await pollFor(timeoutSeconds: 20) {
            let current = try? await self.settleFacts(runID: anchor)
            return current?.isEmpty == false
        }
        XCTAssertTrue(facts)
        let materializationFacts = try await settleFacts(runID: anchor)
        let settleSequence = try XCTUnwrap(materializationFacts.first?.sequence)
        let materialized = await pollFor(timeoutSeconds: 20) {
            let page = self.fixture.events.pollDurable(runID: anchor, afterSequence: 0,
                                                       budgetBytes: 65_536)
            return (page["windowState"] as? String) == "attached"
                && (page["watermark"] as? Int ?? -1) >= settleSequence
        }
        XCTAssertTrue(materialized, "the watermark strictly advances to the committed fact")
        let after = await domain.queueSettleStats
        XCTAssertGreaterThan(after.published - before.published, 0)
        XCTAssertEqual(after.windowUnmaterialized - before.windowUnmaterialized, 0,
            "a valid multi-page backlog is NEVER misclassified as IO failure")
        let degraded = await fixture.events.isSettlePublicationDegraded(runID: anchor)
        XCTAssertFalse(degraded)
        let consumed = await pollFor(timeoutSeconds: 15) {
            let current = try? await self.fixture.inputStore.input(id: row.id)
            return current?.status == .consumed && current?.consumedRunID != nil
        }
        XCTAssertTrue(consumed)
        await pollSettledQuiescence(domain, conversationID: conversationID)
    }

    func testWindowReadFailureKeepsDurableFactAndReportsDegraded() async throws {
        // N6: the fact IS durable (append succeeded) but the window cannot
        // be VERIFIED (store read throws) ⇒ typed degraded on the exact
        // window the host watch polls; consumption/receipt untouched; the
        // lease is released exactly once.
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let anchor = try await makeSyntheticTerminalRun(conversationID: conversationID,
                                                        goal: "window-fail anchor")
        let row = try await enqueueRow(conversationID: conversationID,
                                       content: "window fail settle row",
                                       selectedModelID: fixture.modelID)
        let failing = WindowFailingRunStore(wrapped: fixture.runStore, failingAnchor: anchor)
        let bundle = RunPersistenceBundle(identity: .ordinary,
                                          conversations: fixture.conversationStore,
                                          runs: failing,
                                          runningInputs: fixture.inputStore,
                                          launches: fixture.launchStore,
                                          childRuns: fixture.childStore,
                                          intelligence: fixture.intelligence)
        let before = await domain.queueSettleStats
        let registryBefore = await RuntimeOwnedWorkRegistry.shared.count(for: fixture.epoch)
        await domain.dispatchQueuedInputDrain(conversationID: conversationID,
                                              bundle: bundle,
                                              anchorRunID: anchor)
        await pollSettledQuiescence(domain, conversationID: conversationID)
        let journal = try await fixture.runStore.events(runID: anchor)
        let durable = journal.contains { record in
            guard record.kind == .notice,
                  let data = record.payloadJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return (object["reason"] as? String) == FacadeRunDomain.queueSettleReason
        }
        XCTAssertTrue(durable, "the committed fact survives window failure (durable truth)")
        let after = await domain.queueSettleStats
        XCTAssertEqual(after.windowUnmaterialized - before.windowUnmaterialized, 1,
            "unverifiable window counted exactly once")
        let degraded = await fixture.events.isSettlePublicationDegraded(runID: anchor)
        XCTAssertTrue(degraded)
        let page = fixture.events.pollDurable(runID: anchor, afterSequence: 0,
                                              budgetBytes: 65_536)
        XCTAssertEqual(page["resyncRequired"] as? Bool, true)
        let stored = try unwrapAsync(await fixture.inputStore.input(id: row.id))
        XCTAssertEqual(stored.status, .consumed)
        XCTAssertNotNil(stored.consumedRunID)
        let leases = await domain.queueDrainLeases[conversationID] == nil
        XCTAssertTrue(leases, "the exact-token detach-last tail ran despite the degrade")
        let allOwnedWorkSettled = await pollFor(timeoutSeconds: 15) {
            RuntimeOwnedWorkRegistry.shared.count(for: self.fixture.epoch) == registryBefore
        }
        XCTAssertTrue(allOwnedWorkSettled,
                      "queue-lane quiescence can precede the real follow-up run's owned cleanup")
        let registryAfter = await RuntimeOwnedWorkRegistry.shared.count(for: fixture.epoch)
        XCTAssertEqual(registryAfter, registryBefore,
            "exact-token detach-last leaves no registry residue after the whole chain settles")
    }

    func testParkedDutyAnchorInheritanceAndChainBits() async throws {
        // N7 (QREV-02 coalesced shape): lane #1 pinned at its claim; a
        // second anchored dispatch PARKS and records its DUTY anchor. The
        // first exit publishes lane=refused with the truthful-at-
        // construction chain=OPEN (the park exists); the honoring
        // re-dispatch publishes its OWN duty anchor with chain=CLOSED
        // (nothing parked while lane #2 ran). The ORIGINAL parked-wakeup
        // evidence assertion (feedEvidence delta 2) is preserved verbatim.
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let anchorA1 = try await makeSyntheticTerminalRun(conversationID: conversationID,
                                                          goal: "parked duty A1")
        let anchorA2 = try await makeSyntheticTerminalRun(conversationID: conversationID,
                                                          goal: "parked duty A2")
        let row = try await enqueueRow(conversationID: conversationID,
                                       content: "queued foreign mode c09",
                                       selectedModelID: fixture.modelID,
                                       executionMode: "weirdMode")
        let writerGate = WriterHoldGate()
        defer { writerGate.releaseWriter() }
        writerGate.hold(fixture.database)
        let evidenceBefore = await domain.feedEvidence[conversationID]?.count ?? 0
        await domain.dispatchQueuedInputDrain(conversationID: conversationID,
                                              bundle: domain.durable,
                                              anchorRunID: anchorA1)
        let laneActive = await domain.queueDrainActive.contains(conversationID)
        XCTAssertTrue(laneActive)
        await domain.dispatchQueuedInputDrain(conversationID: conversationID,
                                              bundle: domain.durable,
                                              anchorRunID: anchorA2)
        let parkedFlag = await domain.queueDrainRecheck.contains(conversationID)
        XCTAssertTrue(parkedFlag)
        let dutyAtPark = await domain.queueDrainDuties[conversationID]
        XCTAssertEqual(dutyAtPark, anchorA2,
            "the park records the parking terminal's anchor: the follow-up publishes where the host's CURRENT watch reads")
        writerGate.releaseWriter()
        await pollSettledQuiescence(domain, conversationID: conversationID)
        let factsA1 = try await settleFacts(runID: anchorA1)
        XCTAssertEqual(factsA1.count, 1)
        XCTAssertEqual(factsA1.first?.payload["lane"] as? String, "refused")
        XCTAssertEqual(factsA1.first?.payload["chain"] as? String, "open",
            "a park exists while this lane exits — the successor is guaranteed")
        let factsA2 = try await settleFacts(runID: anchorA2)
        XCTAssertEqual(factsA2.count, 1)
        XCTAssertEqual(factsA2.first?.payload["lane"] as? String, "refused")
        XCTAssertEqual(factsA2.first?.payload["chain"] as? String, "closed",
            "nothing parked while the honoring lane ran — the refusal-at-rest closes the chain")
        let evidenceAfter = await domain.feedEvidence[conversationID]?.count ?? 0
        XCTAssertEqual(evidenceAfter - evidenceBefore, 2,
            "the parked wakeup must produce exactly ONE real bounded re-dispatch (existing lease-evidence trail): a dropped wakeup leaves 1, a spin leaves more")
        let stored = try unwrapAsync(await fixture.inputStore.input(id: row.id))
        XCTAssertEqual(stored.status, .queued)
        XCTAssertEqual(stored.content, "queued foreign mode c09",
                       "the refused row keeps its original body byte-intact")
        XCTAssertEqual(fixture.adapter.requestCount, 0,
                       "a refusing head row never reaches the provider, honored re-dispatch included")
    }

    func testSiblingSkipPublishesDeferredFactUnderDedicatedLease() async throws {
        // N8 (QREV-02 sibling race): a live sibling makes the dispatch a
        // REAL observation boundary. The skip publishes lane=DEFERRED
        // chain=OPEN under its own short attach→publish→exact-token-detach
        // lease (delete drain waits the feed evidence); the row is NOT
        // consumed; only the sibling ever reached the provider.
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let anchor = try await makeSyntheticTerminalRun(conversationID: conversationID,
                                                        goal: "sibling skip anchor")
        let row = try await enqueueRow(conversationID: conversationID,
                                       content: "queued under sibling settle",
                                       selectedModelID: fixture.modelID)
        let gate = RunGateBox()
        let stallIndex = fixture.adapter.requestCount
        defer { gate.release() }
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "held sibling")),
            .completed(.init(stopReason: .endTurn)),
        ], stallAfter: 1, gate: gate), forRequest: stallIndex)
        let sibling = try await startRunLive(domain, conversationID: conversationID,
                                             goal: "sibling parked", correlation: "corr-c09-n8")
        await domain.dispatchQueuedInputDrain(conversationID: conversationID,
                                              bundle: domain.durable,
                                              anchorRunID: anchor)
        let factVisible = await pollFor(timeoutSeconds: 15) {
            let facts = (try? await self.settleFacts(runID: anchor)) ?? []
            return facts.first?.payload["lane"] as? String == "deferred"
        }
        XCTAssertTrue(factVisible, "the skip is a durable observation boundary, not a silent return")
        let facts = try await settleFacts(runID: anchor)
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.payload["chain"] as? String, "open",
            "the live sibling guarantees a later terminal fact")
        XCTAssertNil(facts.first?.payload["state"])
        let stored = try unwrapAsync(await fixture.inputStore.input(id: row.id))
        XCTAssertEqual(stored.status, .queued, "a sibling skip never consumes")
        let siblingReachedProvider = await pollFor(timeoutSeconds: 10) {
            self.fixture.adapter.requestCount == 1
        }
        XCTAssertTrue(siblingReachedProvider,
                      "owned registration precedes provider entry; wait for the real held stream")
        XCTAssertEqual(fixture.adapter.requestCount, 1,
                       "only the live sibling reached the provider — no drain launch, no duplicate turn")
        let leaseReleased = await pollFor(timeoutSeconds: 10) {
            await domain.queueDrainLeases[conversationID] == nil
        }
        XCTAssertTrue(leaseReleased,
            "the dedicated short lease detached its exact token last, no await after")
        // Let the sibling settle honestly before teardown.
        gate.release()
        _ = await waitDurableTerminal(fixture: fixture, runID: sibling)
        await pollSettledQuiescence(domain, conversationID: conversationID)
    }

    func testFencedExitPublishesNothing() async throws {
        // N9: root retirement dominating a pinned lane ⇒ NO silent write.
        // The lane is pinned at its claim (writer gate); the fence lands
        // while it awaits; the exit's publication re-proves the fences and
        // REFUSES — the anchor journal stays clean, the lane still releases
        // its exact lease (shutdown waits real completion).
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let anchor = try await makeSyntheticTerminalRun(conversationID: conversationID,
                                                        goal: "fenced anchor")
        let row = try await enqueueRow(conversationID: conversationID,
                                       content: "fenced settle row",
                                       selectedModelID: fixture.modelID)
        let writerGate = WriterHoldGate()
        defer { writerGate.releaseWriter() }
        writerGate.hold(fixture.database)
        let baseline = await RuntimeOwnedWorkRegistry.shared.count(for: fixture.epoch)
        await domain.dispatchQueuedInputDrain(conversationID: conversationID,
                                              bundle: domain.durable,
                                              anchorRunID: anchor)
        let laneActive = await domain.queueDrainActive.contains(conversationID)
        XCTAssertTrue(laneActive, "the lane must be active, pinned at its claim")
        // The PRODUCTION retirement fence (the same entry every existing
        // fence test uses): real root retirement semantics, no synthetic
        // property poke.
        await domain.beginGenerationRetirement()
        writerGate.releaseWriter()
        await pollSettledQuiescence(domain, conversationID: conversationID)
        let facts = try await settleFacts(runID: anchor)
        XCTAssertTrue(facts.isEmpty, "no silent write after root retirement")
        let stats = await domain.queueSettleStats
        XCTAssertEqual(stats.fencedSkipped, 1,
            "the fenced publication refusal is counted (honesty floor)")
        let stored = try unwrapAsync(await fixture.inputStore.input(id: row.id))
        XCTAssertEqual(stored.status, .queued,
                       "the claimed row restored under the fence path stays durable")
        let count = await RuntimeOwnedWorkRegistry.shared.count(for: fixture.epoch)
        XCTAssertEqual(count, baseline,
            "the exact-token detach-last tail still released the lease")
        // No unfence: beginGenerationRetirement is generation-terminal and the
        // fixture teardown retires through the REAL shutdown anyway.
    }
}

// MARK: - C09 settle-publication test doubles (contract §7)

/// Base delegation over the REAL fixture store. `appendEvent` is one writer
/// transaction in the SQLite implementation, so a wrapper throw below
/// cannot leave partial state; everything else is forwarded verbatim
/// (including the protocol-extension members, so overrides stay honest).
private class DelegatingRunStore: RunStore, @unchecked Sendable {
    let wrapped: any RunStore
    init(wrapped: any RunStore) { self.wrapped = wrapped }
    func saveRun(_ run: RunRecord) async throws { try await wrapped.saveRun(run) }
    func run(id: UUID) async throws -> RunRecord? { try await wrapped.run(id: id) }
    func runs(conversationID: UUID) async throws -> [RunRecord] {
        try await wrapped.runs(conversationID: conversationID)
    }
    func recentRuns(conversationID: UUID, limit: Int) async throws -> [RunRecord] {
        try await wrapped.recentRuns(conversationID: conversationID, limit: limit)
    }
    func nonTerminalRuns() async throws -> [RunRecord] { try await wrapped.nonTerminalRuns() }
    func updateRunState(id: UUID, state: String, endedAt: Date?) async throws {
        try await wrapped.updateRunState(id: id, state: state, endedAt: endedAt)
    }
    func assignGoal(runID: UUID, goalID: UUID) async throws {
        try await wrapped.assignGoal(runID: runID, goalID: goalID)
    }
    func appendEvent(runID: UUID, kind: RunEventRecord.Kind,
                     payloadJSON: String) async throws -> RunEventRecord {
        try await wrapped.appendEvent(runID: runID, kind: kind, payloadJSON: payloadJSON)
    }
    func events(runID: UUID) async throws -> [RunEventRecord] { try await wrapped.events(runID: runID) }
    func recentEvents(runID: UUID, limit: Int) async throws -> [RunEventRecord] {
        try await wrapped.recentEvents(runID: runID, limit: limit)
    }
    func earlierEvents(runID: UUID, beforeSequence: Int,
                       limit: Int) async throws -> [RunEventRecord] {
        try await wrapped.earlierEvents(runID: runID, beforeSequence: beforeSequence, limit: limit)
    }
    func events(runID: UUID, afterSequence: Int, limit: Int) async throws -> [RunEventRecord] {
        try await wrapped.events(runID: runID, afterSequence: afterSequence, limit: limit)
    }
    func recordUsage(_ usage: RunUsageRecord) async throws { try await wrapped.recordUsage(usage) }
    func usage(runID: UUID) async throws -> [RunUsageRecord] { try await wrapped.usage(runID: runID) }
    func recordError(_ error: RunErrorRecord) async throws { try await wrapped.recordError(error) }
    func errors(runID: UUID) async throws -> [RunErrorRecord] { try await wrapped.errors(runID: runID) }
    func saveCheckpoint(runID: UUID, conversationID: UUID, formatVersion: Int,
                        state: String, bodyJSON: String) async throws {
        try await wrapped.saveCheckpoint(runID: runID, conversationID: conversationID,
                                         formatVersion: formatVersion, state: state,
                                         bodyJSON: bodyJSON)
    }
    func checkpointBody(runID: UUID) async throws -> String? {
        try await wrapped.checkpointBody(runID: runID)
    }
    func deleteCheckpoint(runID: UUID) async throws { try await wrapped.deleteCheckpoint(runID: runID) }
    func usageStatistics() async throws -> UsageStatistics { try await wrapped.usageStatistics() }
}

/// N3: the anchor's settle append PROVES its entry (entered signal) and then
/// parks off the cooperative pool until released (the WriterHoldGate
/// discipline — occupancy proven, no sleeps-as-races).
private final class GatedPublishRunStore: DelegatingRunStore {
    private let gatedAnchor: UUID
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    init(wrapped: any RunStore, gatedAnchor: UUID) {
        self.gatedAnchor = gatedAnchor
        super.init(wrapped: wrapped)
    }

    override func appendEvent(runID: UUID, kind: RunEventRecord.Kind,
                              payloadJSON: String) async throws -> RunEventRecord {
        if runID == gatedAnchor {
            entered.signal()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    self.release.wait()
                    continuation.resume()
                }
            }
        }
        return try await wrapped.appendEvent(runID: runID, kind: kind, payloadJSON: payloadJSON)
    }

    /// Blocks the TEST thread only (the WriterHoldGate discipline: occupancy
    /// is PROVEN before assertions run; the gated append itself parks on a
    /// global-queue worker, never the cooperative pool).
    func awaitEntered(timeoutSeconds: Double) -> Bool {
        entered.wait(timeout: .now() + timeoutSeconds) == .success
    }

    func releaseAppend() {
        release.signal()
    }
}

/// N4: the anchor's journal append throws (all other writes delegate).
private final class FailingAppendRunStore: DelegatingRunStore {
    private let failingAnchor: UUID
    init(wrapped: any RunStore, failingAnchor: UUID) {
        self.failingAnchor = failingAnchor
        super.init(wrapped: wrapped)
    }
    override func appendEvent(runID: UUID, kind: RunEventRecord.Kind,
                              payloadJSON: String) async throws -> RunEventRecord {
        if runID == failingAnchor {
            throw NSError(domain: "c09-settle-append", code: 42,
                          userInfo: [NSLocalizedDescriptionKey: "injected append failure"])
        }
        return try await wrapped.appendEvent(runID: runID, kind: kind, payloadJSON: payloadJSON)
    }
}

/// N6: the anchor's windowed page READ throws (the durable append and all
/// reads for other runs delegate — the fact is durable, the window is not
/// verifiable: the exact degraded shape).
private final class WindowFailingRunStore: DelegatingRunStore {
    private let failingAnchor: UUID
    init(wrapped: any RunStore, failingAnchor: UUID) {
        self.failingAnchor = failingAnchor
        super.init(wrapped: wrapped)
    }
    override func events(runID: UUID, afterSequence: Int,
                         limit: Int) async throws -> [RunEventRecord] {
        if runID == failingAnchor {
            throw NSError(domain: "c09-settle-window", code: 43,
                          userInfo: [NSLocalizedDescriptionKey: "injected window read failure"])
        }
        return try await wrapped.events(runID: runID, afterSequence: afterSequence, limit: limit)
    }
}

/// Test-only deterministic writer gate (C05 regressions): occupies the
/// GRDB serial writer with a semaphore-blocked transaction so every later
/// write (the drain lane's durable claim, a sibling launch's prepare)
/// queues behind it, while actor state and pool reads stay observable.
/// Occupancy is PROVEN by the entered semaphore before `hold` returns —
/// no sleeps, no races. `releaseWriter` is idempotent-safe and tests also
/// release through `defer` so a failed assertion can never deadlock
/// teardown.
final class WriterHoldGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var task: Task<Void, Never>?

    func hold(_ database: DatabaseManager) {
        task = Task.detached { [self] in
            _ = try? await database.writer { _ in
                self.entered.signal()
                self.release.wait()
                return 0
            }
        }
        entered.wait()
    }

    func releaseWriter() {
        release.signal()
    }
}
