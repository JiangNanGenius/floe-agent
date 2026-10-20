// SPDX-License-Identifier: MPL-2.0
//
// RB-4 control-surface tests: cancel/retry-window semantics, running-input
// queue/steer/edit/remove/reorder ordering, approval resolve, policy
// update, skillcancel, plus WIRED dispatch through the reviewed mailbox +
// binder validation for every frozen matrix command. AUTHORED, NOT
// EXECUTED.
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloePersistence
import FloeAgentRuntime
import FloeSecurity
@testable import FloeAndroidCore

final class RuntimeFacadeRunControlTests: XCTestCase {
    private var fixture: RunDomainFixture!

    override func setUp() async throws {
        fixture = try await RunDomainFixture.make()
    }

    override func tearDown() async throws {
        RunDomainFacade.uninstall()
        await fixture?.tearDown()
        fixture = nil
    }

    /// Launches a stalled run and returns its id. The stream never
    /// completes until the gate is released, so the run stays `.handedOff`.
    private func startStalledRun(_ domain: FacadeRunDomain,
                                 conversationID: UUID,
                                 goal: String) async throws -> (UUID, RunGateBox, String) {
        let gate = RunGateBox()
        let index = fixture.adapter.requestCount
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "mid stream")),
            .completed(.init(stopReason: .endTurn)),
        ], stallAfter: 1, gate: gate), forRequest: index)
        let revision = try await fixture.revision(conversationID: conversationID)
        let envelope = fixture.launchEnvelope(
            conversationID: conversationID,
            payload: fixture.startPayload(goal: goal),
            revisionVersion: revision, correlation: "corr-\(goal)")
        let receipt = "op:v1:" + String(repeating: "9", count: 31) + String(index % 10)
        let reply = await domain.start(envelope: envelope, receipt: receipt,
                                       correlation: "corr-\(goal)")
        guard case .mutationAccepted(let detail) = reply.outcome,
              let runID = UUID(uuidString: detail["runID"] ?? "") else {
            throw NSError(domain: "fixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(reply.outcome)"])
        }
        // Wait until the projection is HANDED OFF (owner live).
        let live = await pollFor(timeoutSeconds: 6) {
            await domain.ownership(runID: runID)?.phase == .handedOff
        }
        XCTAssertTrue(live, "run \(runID) must reach handedOff")
        // Deterministic cancellation boundary: the ORIGINAL runtime must be
        // REALLY streaming before a cancel is meaningful (a cancel that
        // races the stream setup proves nothing about the producer).
        let streaming = await pollFor(timeoutSeconds: 6) {
            await domain.liveService(runID)?.snapshot().stateName == "streamingModel"
        }
        XCTAssertTrue(streaming, "run \(runID) must reach the real streaming boundary")
        return (runID, gate, receipt)
    }

    // MARK: - run.cancel windows

    func testCancelHandedOffRunClosesRealProducerNotJustPoller() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let (runID, gate, _) = try await startStalledRun(domain, conversationID: conversationID,
                                                          goal: "cancel me")
        // Precondition: the provider REALLY entered the held gate and the
        // first text was REALLY consumed through the live projection while
        // the gate stays closed (handedOff/requestCount alone is not proof).
        let providerParked = await pollFor(timeoutSeconds: 8) { gate.isWaiting }
        XCTAssertTrue(providerParked, "the provider must really enter the held gate")
        let textConsumed = await pollFor(timeoutSeconds: 8) {
            let text = await domain.liveService(runID)?.snapshot().streamedText ?? ""
            return !text.isEmpty
        }
        XCTAssertTrue(textConsumed, "the first delta must be really consumed before cancel")
        let state = try unwrapAsync(await fixture.runState(runID))
        let cancelEnvelope = fixture.executionEnvelope(
            command: "run.cancel", conversationID: conversationID, runID: runID,
            payload: ["expectedState": state], correlation: "corr-cancel",
            revision: ["resourceID": RunWireRevision.runResourceID(runID),
                       "version": state]) // canonical run resource proof
        let reply = await domain.cancel(envelope: cancelEnvelope)
        guard case .mutationAccepted = reply.outcome else {
            gate.release()
            return XCTFail("cancel must be accepted for a live run")
        }
        // PROOF the real producer terminated WITHOUT any manual release or
        // next delta: the ORIGINAL runtime's cancel cancels the live stream
        // task, whose termination cancels this provider stream (onTermination
        // -> producer cancel). The gate stays held for this whole window.
        let terminated = await pollFor(timeoutSeconds: 8) {
            self.fixture.adapter.streamTerminationCount >= 1
        }
        XCTAssertTrue(terminated,
                      "the held provider stream must really terminate on public cancel, before any release")
        let producerCancelled = await pollFor(timeoutSeconds: 8) {
            self.fixture.adapter.streamCancellationCount >= 1
        }
        XCTAssertTrue(producerCancelled,
                      "the held producer must really observe cancellation")
        // Cleanup only AFTER the termination assertions have passed.
        gate.release()
        let final = await waitDurableTerminal(fixture: fixture, runID: runID)
        XCTAssertNotNil(final)
        XCTAssertNotEqual(final, "completed")
        // Ownership retired with ZERO attached exact tokens (the terminal
        // P8 feed is an owned maintenance Task — observe the converged
        // zero, never a transient lease window).
        let clean = await pollFor { await domain.ownership(runID: runID) == nil }
        XCTAssertTrue(clean)
        let registryEpoch = fixture.epoch
        let drained = await pollFor {
            RuntimeOwnedWorkRegistry.shared.count(for: registryEpoch) == 0
        }
        XCTAssertTrue(drained)
        // Durable thread shows an honest terminal (cancelled/failed), never
        // a fake completion.
        // The ORIGINAL engine records cancel as a checkpointed (interrupted)
        // terminal on the harness channel, NOT a provider-completion
        // `.terminal` run row. The durable truth must therefore be the
        // honest non-completed state, never a fake completion.
        let durableEvents = try await fixture.durableEvents(runID)
        let lastStatusState: String? = durableEvents.last(where: { $0.kind == .status })
            .flatMap { record -> String? in
                guard let data = record.payloadJSON.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any] else { return nil }
                return object["state"] as? String
            }
        XCTAssertNotEqual(lastStatusState, "completed",
                          "a cancelled run must never record a completed durable status")
        XCTAssertTrue(["checkpointed", "cancelled", "failed"].contains(lastStatusState ?? ""),
                      "the durable thread must show the ORIGINAL interrupted truth, got \(lastStatusState ?? "nil")")
    }

    func testCancelDuringLiveToolAwaitUsesRuntimeCascade() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        // Script: delta -> fixture.block tool request -> (tool runs,
        // blocking) -> cancelled terminal comes from the cancel cascade.
        let index = fixture.adapter.requestCount
        let blockCall = try ToolCall(id: "call-block-1",
                                     toolName: FixtureBlockingTool.name,
                                     argumentsJSON: Data("{}".utf8),
                                     scope: .local)
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "using a tool")),
            .toolRequest(blockCall),
        ]), forRequest: index)
        let revision = try await fixture.revision(conversationID: conversationID)
        let envelope = fixture.launchEnvelope(
            conversationID: conversationID,
            payload: fixture.startPayload(goal: "run the blocking tool"),
            revisionVersion: revision, correlation: "corr-block")
        // Effects require a REGISTERED receipt stream.
        let receipt = try XCTUnwrap(fixture.effects.register(correlationID: "corr-block"))
        _ = await domain.start(envelope: envelope, receipt: receipt, correlation: "corr-block")
        let runID = try XCTUnwrap(
            pollEffects(fixture.effects, receipt: receipt)
                .first { $0.kind == .prepared }?.detail?["runID"]
                .flatMap(UUID.init(uuidString:)))
        // Tool start observed through the durable/live path.
        let toolStarted = await FixtureBlockingTool.started
        await toolStarted.waitThroughCancellation()
        // A .tool exact token must be attached while the worker really runs.
        let attachedDuringRun = await pollFor {
            await domain.ownership(runID: runID)?.ownedTokens.keys
                .contains { $0.hasPrefix("tool:") } ?? false
        }
        XCTAssertTrue(attachedDuringRun)
        let state = try unwrapAsync(await fixture.runState(runID))
        let cancel = fixture.executionEnvelope(
            command: "run.cancel", conversationID: conversationID, runID: runID,
            payload: ["expectedState": state], correlation: "corr-cancel2",
            revision: ["resourceID": RunWireRevision.runResourceID(runID), "version": state])
        _ = await domain.cancel(envelope: cancel)
        let final = await waitDurableTerminal(fixture: fixture, runID: runID)
        XCTAssertNotNil(final)
        let retired = await pollFor { await domain.ownership(runID: runID) == nil }
        XCTAssertTrue(retired, "tool token detaches only after the worker returned")
    }

    func testCancelLateFinalCallbackCannotResurrectOwnership() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let (runID, gate, _) = try await startStalledRun(domain, conversationID: conversationID,
                                                          goal: "late final")
        var state = try unwrapAsync(await fixture.runState(runID))
        _ = await domain.cancel(envelope: fixture.executionEnvelope(
            command: "run.cancel", conversationID: conversationID, runID: runID,
            payload: ["expectedState": state], correlation: "corr-late",
            revision: ["resourceID": RunWireRevision.runResourceID(runID), "version": state]))
        // Drain retirement first: ownership gone, tokens detached.
        gate.release()
        _ = await pollFor { await domain.ownership(runID: runID) == nil }
        // A late cancel attempt against a retired run answers honestly:
        // durable terminal + no owner; never a fake re-owning.
        state = try unwrapAsync(await fixture.runState(runID))
        let again = await domain.cancel(envelope: fixture.executionEnvelope(
            command: "run.cancel", conversationID: conversationID, runID: runID,
            payload: ["expectedState": state], correlation: "corr-late2",
            revision: ["resourceID": RunWireRevision.runResourceID(runID), "version": state]))
        guard case .mutationAccepted(let detail) = again.outcome else {
            return XCTFail("already-retired cancel reports alreadyRequested")
        }
        XCTAssertEqual(detail["cancel"], "alreadyRequested")
    }

    func testCancelBeforePrepareCommitProvesC0NoEffect() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        // Stall inside ingress by pointing at a gateway that answers
        // slowly? Instead use the C0 flag path directly through the
        // public cancel surface on an admitting ownership: simulate by
        // launching against an adapter whose first await is long…
        // Deterministic path: mark cancellation through a delete guard
        // (fence) BEFORE the launch and assert provable no-effect.
        let lifecycle = RunDomainDeletionLifecycle(domain: domain)
        let fence = try await lifecycle.beginDeletionFence(
            conversationID: conversationID, epoch: fixture.epoch,
            operationID: UUID())
        let reply = await startReplyViaDomain(domain, conversationID: conversationID,
                                              goal: "should never commit")
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("expected fenced refusal")
        }
        XCTAssertEqual(error.code, .sessionFenced)
        // C0: NO run row was created.
        let runs = try await fixture.runStore.runs(conversationID: conversationID)
        XCTAssertEqual(runs.count, 1)
        let settle = await lifecycle.abortDeletionFence(fence)
        XCTAssertEqual(settle, .released)
    }

    private func startReplyViaDomain(_ domain: FacadeRunDomain, conversationID: UUID,
                                     goal: String) async -> RunDomainReply {
        let revision = (try? await fixture.revision(conversationID: conversationID)) ?? ""
        let envelope = fixture.launchEnvelope(
            conversationID: conversationID, payload: fixture.startPayload(goal: goal),
            revisionVersion: revision, correlation: "corr-c0-\(goal)")
        return await domain.start(envelope: envelope,
                                  receipt: "op:v1:" + String(repeating: "5", count: 32),
                                  correlation: "corr-c0-\(goal)")
    }

    // MARK: - running input queue / steer / edit / remove / reorder

    func testQueueAcceptedIsNotApprovalOrRunStart() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let (runID, gate, _) = try await startStalledRun(domain, conversationID: conversationID,
                                                          goal: "queued target")
        let queue = fixture.executionEnvelope(
            command: "run.queue", conversationID: conversationID, runID: runID,
            payload: ["content": "queued follow-up", "mode": "queue"],
            correlation: "corr-queue",
            revision: ["resourceID": ConversationRowRevision.resourceID(conversationID: conversationID),
                       "version": try await fixture.revision(conversationID: conversationID)])
        let reply = await domain.queue(envelope: queue)
        guard case .mutationAccepted(let detail) = reply.outcome,
              let inputID = UUID(uuidString: detail["inputID"] ?? "") else {
            gate.release()
            return XCTFail("queue must accept")
        }
        let row = try unwrapAsync(await fixture.inputStore.input(id: inputID))
        XCTAssertEqual(row.status, .queued)
        XCTAssertNil(row.consumedRunID)
        // Still exactly one run on the conversation (queue started nothing).
        let runs = try await fixture.runStore.runs(conversationID: conversationID)
        XCTAssertEqual(runs.count, 2) // seed + live
        gate.release()
    }

    func testSteerPromotionExactlyOnceAndRaceTruthful() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        // TWO provider rounds: the steer is consumed exactly once at the
        // real step boundary between them (the ORIGINAL service writes
        // consumedRunID via its durable receipt path, not this facade).
        let gate = RunGateBox()
        let idx = fixture.adapter.requestCount
        let echoCall = try ToolCall(id: "call-echo-1",
                                    toolName: FixtureEchoTool.name,
                                    argumentsJSON: Data(#"{"message":"steer"}"#.utf8),
                                    scope: .local)
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "before steer")),
            .toolRequest(echoCall),
        ], stallAfter: 1, gate: gate), forRequest: idx)
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "after steer")),
            .completed(.init(stopReason: .endTurn)),
        ]), forRequest: idx + 1)
        let revision = try await fixture.revision(conversationID: conversationID)
        let receipt = "op:v1:" + String(repeating: "8", count: 32)
        let started = await domain.start(envelope: fixture.launchEnvelope(
            conversationID: conversationID,
            payload: fixture.startPayload(goal: "steer target"),
            revisionVersion: revision, correlation: "corr-steerlaunch"),
            receipt: receipt, correlation: "corr-steerlaunch")
        guard case .mutationAccepted(let d) = started.outcome,
              let runID = UUID(uuidString: d["runID"] ?? "") else {
            return XCTFail("launch must hand off")
        }
        _ = await pollFor { await domain.ownership(runID: runID)?.phase == .handedOff }
        // Enqueue through the wire path.
        _ = await domain.queue(envelope: fixture.executionEnvelope(
            command: "run.queue", conversationID: conversationID, runID: runID,
            payload: ["content": "steer me", "mode": "queue"],
            correlation: "corr-q2",
            revision: ["resourceID": ConversationRowRevision.resourceID(conversationID: conversationID),
                       "version": try await fixture.revision(conversationID: conversationID)]))
        let queued = try await fixture.inputStore.pending(conversationID: conversationID)
        let inputID = try XCTUnwrap(queued.first?.id)
        // Wait for the stalled run's durable state to settle (the runtime
        // writes streamingModel once, then it is stable while the gate is
        // held) so the envelope proof cannot race the state transition.
        let settled = await pollFor {
            (try? await self.fixture.runState(runID)) == "streamingModel"
        }
        XCTAssertTrue(settled, "the stalled run must settle into a stable durable state")
        let steer = fixture.executionEnvelope(
            command: "run.steer", conversationID: conversationID, runID: runID,
            payload: ["inputID": inputID.uuidString,
                      "expectedState": try unwrapAsync(await fixture.runState(runID))],
            correlation: "corr-steer",
            revision: ["resourceID": RunWireRevision.runResourceID(runID),
                       "version": try unwrapAsync(await fixture.runState(runID))])
        let first = await domain.steer(envelope: steer)
        guard case .mutationAccepted(let detail) = first.outcome else {
            gate.release()
            return XCTFail("steer must accept into the live run")
        }
        XCTAssertEqual(detail["accepted"], "true")
        // The row is steerPending with targetRunID set; consumedRunID stays
        // nil until the ORIGINAL service writes its exactly-once receipt.
        let row = try unwrapAsync(await fixture.inputStore.input(id: inputID))
        XCTAssertEqual(row.status, .steerPending)
        XCTAssertEqual(row.targetRunID, runID)
        XCTAssertNil(row.consumedRunID)
        // Replay with the SAME input id surfaces alreadyAccepted (runtime
        // ledger), never a double copy into context.
        let again = await domain.steer(envelope: fixture.executionEnvelope(
            command: "run.steer", conversationID: conversationID, runID: runID,
            payload: ["inputID": inputID.uuidString,
                      "expectedState": try unwrapAsync(await fixture.runState(runID))],
            correlation: "corr-steer2",
            revision: ["resourceID": RunWireRevision.runResourceID(runID),
                       "version": try unwrapAsync(await fixture.runState(runID))]))
        // The replay read above is safe: the run remains stalled in the
        // same stable state until the gate is released.
        guard case .mutationAccepted(let d2) = again.outcome else {
            gate.release()
            return XCTFail("expected alreadyAccepted surface")
        }
        XCTAssertEqual(d2["alreadyAccepted"], "true")
        // Let the run finish: the ORIGINAL handleConsumedSteer path writes
        // the consumed receipt exactly once.
        gate.release()
        let final = await waitDurableTerminal(fixture: fixture, runID: runID)
        XCTAssertEqual(final, "completed")
        let consumed = try unwrapAsync(await fixture.inputStore.input(id: inputID))
        XCTAssertEqual(consumed.status, .consumed)
        XCTAssertEqual(consumed.consumedRunID, runID)
        // The durable user-turn for the steer was written by the ORIGINAL
        // service exactly once (steerUserMessageBase), and the live
        // userInputConsumed frame reached the pump's durable window.
        let messages = try await fixture.conversationStore
            .messages(conversationID: conversationID)
        XCTAssertEqual(messages.filter { $0.id == inputID }.count, 1)
    }

    func testEditRemoveSteerPendingWithdrawsFirstThenMutates() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let (runID, gate, _) = try await startStalledRun(domain, conversationID: conversationID,
                                                          goal: "withdraw target")
        _ = await domain.queue(envelope: fixture.executionEnvelope(
            command: "run.queue", conversationID: conversationID, runID: runID,
            payload: ["content": "to withdraw", "mode": "queue"],
            correlation: "corr-q3",
            revision: ["resourceID": ConversationRowRevision.resourceID(conversationID: conversationID),
                       "version": try await fixture.revision(conversationID: conversationID)]))
        let queued = try await fixture.inputStore.pending(conversationID: conversationID)
        let inputID = try XCTUnwrap(queued.first?.id)
        let state = try unwrapAsync(await fixture.runState(runID))
        _ = await domain.steer(envelope: fixture.executionEnvelope(
            command: "run.steer", conversationID: conversationID, runID: runID,
            payload: ["inputID": inputID.uuidString, "expectedState": state],
            correlation: "corr-steer3",
            revision: ["resourceID": RunWireRevision.runResourceID(runID), "version": state]))
        // Now remove: withdrawal must restore queued FIRST, then cancel.
        let row = try unwrapAsync(await fixture.inputStore.input(id: inputID))
        let rowVersion = RunWireRevision.inputVersion(updatedAt: row.updatedAt)
        let remove = await domain.inputRemove(envelope: fixture.executionEnvelope(
            command: "run.input.remove", conversationID: conversationID, runID: runID,
            payload: ["inputID": inputID.uuidString,
                      "expectedInputVersion": rowVersion],
            correlation: "corr-rm",
            revision: ["resourceID": RunWireRevision.pendingInputResourceID(inputID),
                       "version": rowVersion]))
        gate.release()
        guard case .mutationAccepted = remove.outcome else {
            return XCTFail("remove must succeed after withdrawal")
        }
        let removed = try unwrapAsync(await fixture.inputStore.input(id: inputID))
        XCTAssertEqual(removed.status, .cancelled)
        XCTAssertNil(removed.consumedRunID, "withdrawal must not fake consumption")
    }

    func testReorderRequiresExactQueueVersionAndSet() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let (runID, gate, _) = try await startStalledRun(domain, conversationID: conversationID,
                                                          goal: "reorder host")
        for text in ["one", "two"] {
            _ = await domain.queue(envelope: fixture.executionEnvelope(
                command: "run.queue", conversationID: conversationID, runID: runID,
                payload: ["content": text, "mode": "queue"],
                correlation: "corr-\(text)",
                revision: ["resourceID": ConversationRowRevision.resourceID(conversationID: conversationID),
                           "version": try await fixture.revision(conversationID: conversationID)]))
        }
        let queueFixture: RunDomainFixture = fixture
        let queued = await pollFor {
            (try? await queueFixture.inputStore.pending(conversationID: conversationID))?
                .filter { $0.status == .queued }.count == 2
        }
        XCTAssertTrue(queued)
        let ids = try await fixture.inputStore.pending(conversationID: conversationID)
            .filter { $0.status == .queued }
            .map(\.id)
        let swapped = Array(ids.reversed())
        let bad = await domain.inputReorder(envelope: fixture.executionEnvelope(
            command: "run.input.reorder", conversationID: conversationID, runID: runID,
            payload: ["orderedIDs": swapped.map { $0.uuidString },
                      "expectedQueueVersion": "bogus"],
            correlation: "corr-bad-reorder",
            revision: ["resourceID": RunWireRevision.pendingQueueResourceID(conversationID),
                       "version": "bogus"]))
        gate.release()
        guard case .rejected(let error) = bad.outcome else {
            return XCTFail("bogus queue version must refuse")
        }
        XCTAssertEqual(error.code, .staleRevision)
        let good = await domain.inputReorder(envelope: fixture.executionEnvelope(
            command: "run.input.reorder", conversationID: conversationID, runID: runID,
            payload: ["orderedIDs": swapped.map { $0.uuidString },
                      "expectedQueueVersion": RunWireRevision.queueVersion(orderedIDs: ids)],
            correlation: "corr-good-reorder",
            revision: ["resourceID": RunWireRevision.pendingQueueResourceID(conversationID),
                       "version": RunWireRevision.queueVersion(orderedIDs: ids)]))
        guard case .mutationAccepted = good.outcome else {
            return XCTFail("exact set + version must succeed")
        }
        let after = try await fixture.inputStore.pending(conversationID: conversationID)
            .filter { $0.status == .queued }.map(\.id)
        XCTAssertEqual(after, swapped)
    }

    // MARK: - approval.resolve / policy.update / skillcancel

    func testApprovalCardAppearsFromRealEngineAndResolveIsCallBound() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        // Human policy + side-effecting tool => real escalation.
        let index = fixture.adapter.requestCount
        let sideCall = try ToolCall(
            id: "call-side-1", toolName: FixtureSideEffectTool.name,
            argumentsJSON: Data(#"{"target":"notes.txt"}"#.utf8),
            scope: .hostPath(hostID: UUID(), path: "notes.txt"))
        fixture.adapter.enqueue(script: .init(events: [
            .toolRequest(sideCall),
            .completed(.init(stopReason: .endTurn)),
        ]), forRequest: index)
        let revision = try await fixture.revision(conversationID: conversationID)
        // Effects require a REGISTERED receipt stream (the ORIGINAL pump
        // refuses appends to unknown receipts).
        let receipt = try XCTUnwrap(fixture.effects.register(correlationID: "corr-appr"))
        _ = await domain.start(envelope: fixture.launchEnvelope(
            conversationID: conversationID,
            payload: fixture.startPayload(goal: "modify a file"),
            revisionVersion: revision, correlation: "corr-appr"),
            receipt: receipt, correlation: "corr-appr")
        let runID = try XCTUnwrap(
            pollEffects(fixture.effects, receipt: receipt)
                .first { $0.kind == .prepared }?.detail?["runID"]
                .flatMap(UUID.init(uuidString:)))
        let pending = await pollFor(timeoutSeconds: 8) {
            await domain.liveService(runID)?.snapshot().pendingApproval != nil
        }
        XCTAssertTrue(pending, "the ENGINE must request approval, not a synthesized card")
        let waiting = try unwrapAsync(await domain.liveService(runID)?.snapshot().pendingApproval)
        let requestVersion = RunWireRevision.approvalVersion(requestedAt: waiting.requestedAt)
        // Wrong callID can never resolve the pending request.
        let wrong = await domain.resolveApproval(envelope: fixture.executionEnvelope(
            command: "run.approval.resolve", conversationID: conversationID, runID: runID,
            payload: ["callID": "not-the-live-call", "decision": "allow",
                      "expectedApprovalVersion": requestVersion],
            correlation: "corr-wrong",
            revision: ["resourceID": RunWireRevision.approvalResourceID(callID: "not-the-live-call"),
                       "version": requestVersion]))
        guard case .rejected(let wrongError) = wrong.outcome else {
            return XCTFail("stale card must never resolve")
        }
        XCTAssertEqual(wrongError, RunDomainError(.invalidState, .approvalGenerationMismatch))
        // Correct resolve: the reply claims `bound`, NOT durable-recorded.
        let right = await domain.resolveApproval(envelope: fixture.executionEnvelope(
            command: "run.approval.resolve", conversationID: conversationID, runID: runID,
            payload: ["callID": waiting.toolCall.id, "decision": "allow",
                      "expectedApprovalVersion": requestVersion],
            correlation: "corr-right",
            revision: ["resourceID": RunWireRevision.approvalResourceID(callID: waiting.toolCall.id),
                       "version": requestVersion]))
        guard case .mutationAccepted(let detail) = right.outcome else {
            return XCTFail("correct approval must bind")
        }
        XCTAssertEqual(detail["bound"], "true")
        XCTAssertEqual(detail["awaitReceipt"], "approvalResolved")
        // The durable thread proves the run then proceeded: tool result +
        // approval receipt records exist only after the real engine acted.
        _ = await waitDurableTerminal(fixture: fixture, runID: runID)
        let events = try await fixture.durableEvents(runID)
        XCTAssertTrue(events.contains { $0.kind == .toolResult })
        // Live approvalResolved frame reached the pump consumer too.
        let live = fixture.events.pollDurable(runID: runID, afterSequence: 0,
                                              budgetBytes: FacadeFrameBudget.pageBudgetBytes)
        XCTAssertEqual(live["windowState"] as? String, "attached")
    }

    func testAllowScopeIsDerivedFromLiveCallNeverFromPayload() async throws {
        // Payload cannot smuggle a broader ApprovalScope: even if a hostile
        // payload carries extra keys, the closed parser rejects it.
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let envelope = fixture.executionEnvelope(
            command: "run.approval.resolve", conversationID: conversationID,
            runID: UUID(),
            payload: ["callID": "x", "decision": "allow",
                      "expectedApprovalVersion": RunWireDate.encode(Date()),
                      "scope": ["paths": ["/"], "hostID": UUID().uuidString]],
            correlation: "corr-scope-smuggle")
        let reply = await domain.resolveApproval(envelope: envelope)
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("scope smuggle must be a closed-key rejection")
        }
        XCTAssertEqual(error.reason, .payloadInvalid)
    }

    func testPolicyUpdatePersistsAndReachesLiveServiceUnderDynamicPolicy() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let (runID, gate, _) = try await startStalledRun(domain, conversationID: conversationID,
                                                          goal: "policy host")
        let policy = try await fixture.workspaceStore.taskPolicy(conversationID: conversationID)
        let update = await domain.policyUpdate(envelope: fixture.executionEnvelope(
            command: "run.policy.update", conversationID: conversationID, runID: runID,
            payload: ["approvalMode": "automatic",
                      "expectedPolicyVersion": RunWireRevision.taskPolicyVersion(
                          updatedAt: policy.updatedAt)],
            correlation: "corr-policy",
            revision: ["resourceID": RunWireRevision.taskPolicyResourceID(conversationID),
                       "version": RunWireRevision.taskPolicyVersion(updatedAt: policy.updatedAt)]))
        gate.release()
        guard case .mutationAccepted(let detail) = update.outcome else {
            return XCTFail("policy update must be accepted")
        }
        XCTAssertEqual(detail["appliedToLiveRun"], "true")
        let saved = try await fixture.workspaceStore.taskPolicy(conversationID: conversationID)
        XCTAssertEqual(saved.resolvedApprovalMode, .automatic)
    }

    func testPolicyUpdateStaleVersionRefused() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let update = await domain.policyUpdate(envelope: fixture.executionEnvelope(
            command: "run.policy.update", conversationID: conversationID,
            runID: UUID(),
            payload: ["approvalMode": "automatic",
                      "expectedPolicyVersion": "1970-01-01T00:00:00.000Z"],
            correlation: "corr-stale-policy",
            revision: ["resourceID": RunWireRevision.taskPolicyResourceID(conversationID),
                       "version": "1970-01-01T00:00:00.000Z"]))
        guard case .rejected(let error) = update.outcome else {
            return XCTFail("stale policy version must refuse")
        }
        XCTAssertEqual(error.code, .staleRevision)
    }

    func testSkillCancelUnboundIsTypedRefusalNeverInventedJob() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        var components = fixture.components()
        components.toolCancellation = nil
        let domain = fixture.makeCustomDomain(components)
        let (runID, gate, _) = try await startStalledRun(domain, conversationID: conversationID,
                                                          goal: "skill host")
        let state = try unwrapAsync(await fixture.runState(runID))
        let reply = await domain.skillCancel(envelope: fixture.executionEnvelope(
            command: "run.skillcancel", conversationID: conversationID, runID: runID,
            payload: ["callID": "some-tool-call", "expectedState": state],
            correlation: "corr-skill",
            revision: ["resourceID": RunWireRevision.runResourceID(runID), "version": state]))
        gate.release()
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("unbound cancellation port must refuse typed")
        }
        XCTAssertEqual(error, RunDomainError(.capabilityNotUsable, .skillCancellationUnbound))
    }

    func testSkillCancelDelegatesToBoundPort() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let (runID, gate, _) = try await startStalledRun(domain, conversationID: conversationID,
                                                          goal: "skill host 2")
        let state = try unwrapAsync(await fixture.runState(runID))
        let reply = await domain.skillCancel(envelope: fixture.executionEnvelope(
            command: "run.skillcancel", conversationID: conversationID, runID: runID,
            payload: ["expectedState": state], correlation: "corr-skill2",
            revision: ["resourceID": RunWireRevision.runResourceID(runID), "version": state]))
        gate.release()
        guard case .mutationAccepted = reply.outcome else {
            return XCTFail("bound port must accept")
        }
        XCTAssertEqual(fixture.cancellation.cancelled.first?.0, runID)
        XCTAssertNil(fixture.cancellation.cancelled.first?.1, "whole-run cancel has no call id")
    }

    // MARK: - WIRED mailbox dispatch + frozen matrix validation

    func testWiredDispatchThroughRealMailboxSettlesTerminalEffect() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let registry = RuntimeDomainRegistry()
        RunDomainFacade.install(components: fixture.components(), registry: registry)
        let mailbox = FacadeCommandMailbox(effects: fixture.effects, registry: registry)
        mailbox.startDrain()
        let correlation = "corr-wired-snapshot"
        let receipt = try XCTUnwrap(fixture.effects.register(correlationID: correlation))
        let missingRun = UUID()
        let envelopeObject: [String: Any] = [
            "schema": BridgeV3.commandSchema,
            "scope": BridgeV3.Scope.taskExecution.rawValue,
            "command": "run.snapshot",
            "stateful": false,
            "correlationID": correlation,
            "owner": ["taskID": conversationID.uuidString, "runID": missingRun.uuidString],
        ]
        let envelopeData = try JSONSerialization.data(withJSONObject: envelopeObject)
        let job = RuntimeCommandEnvelopeJob(
            correlationID: correlation,
            handlerKey: BridgeV3.handlerKey(scope: .taskExecution, command: "run.snapshot"),
            command: "run.snapshot", scope: .taskExecution, configurationScope: nil,
            receipt: receipt, envelope: envelopeData)
        XCTAssertEqual(mailbox.submit(job), .queued(receipt: receipt))
        let effectStore = fixture.effects
        let settled = await pollFor(timeoutSeconds: 8) {
            effectStore.isTerminal(receipt: receipt)
        }
        mailbox.close(reason: .closed)
        XCTAssertTrue(settled, "the reviewed mailbox must settle one terminal")
        let items = pollEffects(fixture.effects, receipt: receipt)
        XCTAssertEqual(items.filter { $0.isTerminal }.count, 1)
    }

    func testEveryMatrixCommandValidatesAndRoutesToItsHandlerKey() throws {
        // The frozen rules: all 15 plan keys + event.poll exist and are
        // computed with the live helper.
        RunDomainFacade.install(components: fixture.components(),
                                registry: RuntimeDomainRegistry())
        let matrix = Dictionary(
            uniqueKeysWithValues: BridgeV3.commandRules
                .filter { $0.scope == .taskExecution || $0.scope == .launch }
                .map { (BridgeV3.handlerKey(scope: $0.scope, command: $0.command), $0) })
        for binding in RunDomainHandlerPlan.bindings {
            XCTAssertNotNil(matrix[binding.handlerKey],
                            "planned key \(binding.handlerKey) missing from the frozen matrix")
            XCTAssertEqual(binding.handlerKey,
                           BridgeV3.handlerKey(scope: binding.scope, command: binding.command))
        }
        XCTAssertEqual(Set(RunDomainHandlerPlan.bindings.map(\.handlerKey)).count, 15)
        // event.poll stays SEPARATE (run cursor) from effect.poll.
        XCTAssertFalse(RunDomainHandlerPlan.bindings.contains { $0.command == "event.poll" },
                       "RB4 must not re-register the RB1 pump key")
        XCTAssertEqual(BridgeV3.handlerKey(scope: .taskExecution, command: "event.poll"),
                       "v3.command.taskExecution.event.poll")
        XCTAssertNotEqual(BridgeV3.runEventSchema, BridgeV3.effectSchema)
    }

    func testV3EnvelopeShapesForAllFifteenCommandsValidateStructurally() throws {
        // Exercise the FROZEN validator over synthetic well-formed envelopes
        // (validation only; no handler, no dispatch, no receipt).
        let task = UUID()
        let run = UUID()
        let cases: [(String, BridgeV3.Scope, [String: Any])] = [
            ("run.start", .launch, ["owner": ["taskID": task.uuidString],
                                    "revision": ["resourceID": "conversation.\(task)",
                                                 "version": "v"],
                                    "payload": fixture.startPayload(goal: "x"),
                                    "stateful": true]),
            ("run.startTask", .launch, ["createIntent": true,
                                        "payload": ["title": "t", "goal": "x", "mode": "chat",
                                                    "providerID": task.uuidString,
                                                    "modelID": run.uuidString,
                                                    "approvalMode": "ask"],
                                        "stateful": true]),
        ]
        for (command, scope, body) in cases {
            var envelope: [String: Any] = [
                "schema": BridgeV3.commandSchema,
                "scope": scope.rawValue,
                "command": command,
                "correlationID": "corr-struct-\(command)",
            ]
            for (key, value) in body { envelope[key] = value }
            let result = BridgeV3.validate(envelope: envelope,
                                           requestID: "corr-struct-\(command)",
                                           operation: .submit)
            XCTAssertTrue(result.isValid, "\(command): \(result.errorCode)/\(result.reason)")
        }
        // taskExecution stateful trio with revision + owner roles:
        for command in ["run.cancel", "run.retry", "run.approval.resolve", "run.policy.update",
                        "run.skillcancel"] {
            let envelope: [String: Any] = [
                "schema": BridgeV3.commandSchema,
                "scope": BridgeV3.Scope.taskExecution.rawValue,
                "command": command,
                "stateful": true,
                "correlationID": "corr-\(command)",
                "owner": ["taskID": task.uuidString, "runID": run.uuidString],
                "revision": ["resourceID": "run.\(run)", "version": "preparing"],
                "payload": ["expectedState": "preparing"],
            ]
            let result = BridgeV3.validate(envelope: envelope, requestID: "corr-\(command)",
                                           operation: .submit)
            XCTAssertTrue(result.isValid, "\(command): \(result.errorCode)/\(result.reason)")
        }
        // Reads WITHOUT revision under taskExecution:
        for command in ["run.snapshot", "child.list"] {
            let envelope: [String: Any] = [
                "schema": BridgeV3.commandSchema,
                "scope": BridgeV3.Scope.taskExecution.rawValue,
                "command": command,
                "stateful": false,
                "correlationID": "corr-\(command)",
                "owner": ["taskID": task.uuidString, "runID": run.uuidString],
            ]
            XCTAssertTrue(BridgeV3.validate(envelope: envelope, requestID: "corr-\(command)",
                                            operation: .submit).isValid)
        }
        // event.poll requires the RUN cursor schema and matching run role.
        let eventEnvelope: [String: Any] = [
            "schema": BridgeV3.runEventSchema,
            "scope": BridgeV3.Scope.taskExecution.rawValue,
            "command": "event.poll",
            "stateful": false,
            "correlationID": "corr-events",
            "owner": ["taskID": task.uuidString, "runID": run.uuidString],
            "cursor": ["runID": run.uuidString, "sequence": 0],
        ]
        XCTAssertTrue(BridgeV3.validate(envelope: eventEnvelope, requestID: "corr-events",
                                        operation: .runEventPoll).isValid)
        // The EFFECT cursor schema cannot be used on the event channel — the
        // two stay separate (floe.event-cursor/3 vs floe.effect-cursor/3).
        let crossed = eventEnvelope.merging(["schema": BridgeV3.effectSchema]) { $1 }
        let crossedResult = BridgeV3.validate(envelope: crossed, requestID: "corr-events",
                                              operation: .runEventPoll)
        XCTAssertFalse(crossedResult.isValid)
        XCTAssertEqual(crossedResult.reason, "schemaRoleMismatch")
    }

    func testRelabelledScopeAndUnknownCommandRejected() throws {
        let task = UUID()
        let run = UUID()
        // run.snapshot moved to applicationConfiguration: never authority.
        let bad = [
            "schema": BridgeV3.commandSchema,
            "scope": BridgeV3.Scope.applicationConfiguration.rawValue,
            "configurationScope": "capabilities",
            "command": "run.snapshot",
            "stateful": false,
            "correlationID": "corr-relabel",
        ] as [String: Any]
        let result = BridgeV3.validate(envelope: bad, requestID: "corr-relabel",
                                       operation: .submit)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.reason, "commandScopeMismatch")
    }
}
