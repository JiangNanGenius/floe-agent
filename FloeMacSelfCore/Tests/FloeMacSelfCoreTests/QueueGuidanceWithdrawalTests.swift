// SPDX-License-Identifier: MPL-2.0
//
// Queue guidance withdrawal (host "Back to queue" demote) tests for the Mac
// self-core hook. The hook must move an accepted-but-unconsumed guidance row
// back to the ordinary queue with its original content and model/workspace/
// mode binding intact, and it must fail closed everywhere else: a consumed
// row stays consumed, a plain queued row is untouched, and a finished session
// never demotes (the confirmed-terminal sweep already requeued the row).
// Every root is a unique 0700 temporary directory; no user database or
// credential is touched.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime
@testable import FloeMacSelfCore

@Suite("Mac self-core queue guidance withdrawal")
struct QueueGuidanceWithdrawalTests {

    @Test("Withdrawing unconsumed guidance returns one queued row with original metadata")
    func withdrawUnconsumedGuidanceReturnsRowToQueue() async throws {
        try await withSelfCoreFixture { fixture in
            let steerText = "demote me back to the queue"
            let steerID = UUID()
            let (provider, adapter) = fixture.makeProvider(
                scripts: [[
                    .textDelta(.init(text: "First answer.")),
                    .completed(.init(stopReason: .endTurn)),
                ]],
                holdFirstEvent: true
            )
            let handle = try await fixture.runtime.startSession(
                fixture.newConversationRequest(goal: "Withdraw guidance before consumption"),
                provider: provider
            )
            let running = await eventually {
                let snapshot = await handle.snapshot()
                return snapshot?.stateName == "streamingModel" && adapter.requests.count == 1
            }
            try #require(running)
            let store = try await fixture.runtime.runningInputStore()

            #expect(try await handle.steer(
                text: steerText,
                inputID: steerID,
                expectedConversationID: handle.identity.conversationID,
                expectedRunID: handle.identity.runID,
                executionMode: "chat"
            ))
            let pending = try #require(await store.input(id: steerID))
            #expect(pending.status == .steerPending)
            #expect(pending.targetRunID == handle.identity.runID)

            // The demote wins the race with consumption: true, and the row is
            // durably queued again with every original binding preserved.
            #expect(await handle.withdrawSteer(id: steerID))
            let demoted = try #require(await store.input(id: steerID))
            #expect(demoted.status == .queued)
            #expect(demoted.mode == .queue)
            #expect(demoted.targetRunID == nil)
            #expect(demoted.consumedRunID == nil)
            #expect(demoted.consumedAt == nil)
            #expect(demoted.content == steerText)
            #expect(demoted.selectedModelID == provider.model.id)
            #expect(demoted.workspaceID == handle.identity.workspaceID)
            #expect(demoted.executionMode == "chat")

            // The withdrawn guidance never reached the runtime: completing the
            // held first turn ends the run without a second provider request,
            // and the restored row waits in the queue untouched.
            await adapter.openGate()
            let terminal = try #require(await handle.waitForTerminal(timeout: 15))
            #expect(terminal.confirmed)
            #expect(terminal.outcome == .completed)
            #expect(adapter.requests.count == 1)
            let messages = try await fixture.runtime.conversationMessages(
                conversationID: handle.identity.conversationID)
            #expect(!messages.contains { $0.content == steerText })

            let afterTerminal = try await store.pending(conversationID: handle.identity.conversationID)
            #expect(afterTerminal.count == 1)
            #expect(afterTerminal.first?.id == steerID)
            #expect(afterTerminal.first?.status == .queued)

            let close = try await handle.close()
            #expect(close.terminalConfirmed)
        }
    }

    @Test("Withdrawing consumed guidance fails closed and the row stays consumed")
    func withdrawConsumedGuidanceFailsClosed() async throws {
        try await withSelfCoreFixture { fixture in
            let steerText = "guidance the runtime already ate"
            let steerID = UUID()
            let (provider, adapter) = fixture.makeProvider(
                scripts: [
                    [
                        .textDelta(.init(text: "First answer.")),
                        .completed(.init(stopReason: .endTurn)),
                    ],
                    [
                        .textDelta(.init(text: "Second answer.")),
                        .completed(.init(stopReason: .endTurn)),
                    ],
                ],
                holdFirstEvent: true
            )
            let handle = try await fixture.runtime.startSession(
                fixture.newConversationRequest(goal: "Consume guidance before demote"),
                provider: provider
            )
            let running = await eventually {
                let snapshot = await handle.snapshot()
                return snapshot?.stateName == "streamingModel" && adapter.requests.count == 1
            }
            try #require(running)
            let store = try await fixture.runtime.runningInputStore()

            #expect(try await handle.steer(
                text: steerText,
                inputID: steerID,
                expectedConversationID: handle.identity.conversationID,
                expectedRunID: handle.identity.runID
            ))
            await adapter.openGate()
            let terminal = try #require(await handle.waitForTerminal(timeout: 15))
            #expect(terminal.confirmed)
            #expect(terminal.outcome == .completed)

            // Consumption is durable and exactly-once before the demote ask.
            let consumed = try #require(await store.input(id: steerID))
            #expect(consumed.status == .consumed)
            #expect(consumed.consumedRunID == handle.identity.runID)
            #expect(adapter.requests.count == 2)
            let secondRequest = try #require(adapter.requests.dropFirst().first)
            #expect(secondRequest.messages.contains { $0.role == "user" && $0.content == steerText })

            // Demoting a sent message is refused: false, row stays consumed,
            // and the transcript is unchanged.
            #expect(await handle.withdrawSteer(id: steerID) == false)
            let stillConsumed = try #require(await store.input(id: steerID))
            #expect(stillConsumed.status == .consumed)
            #expect(stillConsumed.consumedRunID == handle.identity.runID)
            #expect(try await store.pending(conversationID: handle.identity.conversationID).isEmpty)

            let close = try await handle.close()
            #expect(close.terminalConfirmed)
        }
    }

    @Test("Withdrawing a plain queued row fails closed and keeps it queued")
    func withdrawQueuedRowFailsClosed() async throws {
        try await withSelfCoreFixture { fixture in
            let (provider, adapter) = fixture.makeProvider(
                scripts: [[
                    .textDelta(.init(text: "Terminal answer.")),
                    .completed(.init(stopReason: .endTurn)),
                ]],
                holdFirstEvent: true
            )
            let handle = try await fixture.runtime.startSession(
                fixture.newConversationRequest(goal: "Queued row is not guidance"),
                provider: provider
            )
            let running = await eventually {
                let snapshot = await handle.snapshot()
                return snapshot?.stateName == "streamingModel" && adapter.requests.count == 1
            }
            try #require(running)
            let store = try await fixture.runtime.runningInputStore()
            let queued = try await store.enqueue(PendingUserInput(
                conversationID: handle.identity.conversationID,
                content: "plain queued message",
                selectedModelID: provider.model.id,
                workspaceID: handle.identity.workspaceID,
                executionMode: "chat"
            ))

            #expect(await handle.withdrawSteer(id: queued.id) == false)
            let unchanged = try #require(await store.input(id: queued.id))
            #expect(unchanged.status == .queued)
            #expect(unchanged.mode == .queue)
            #expect(unchanged.content == "plain queued message")

            await adapter.openGate()
            let terminal = try #require(await handle.waitForTerminal(timeout: 15))
            #expect(terminal.confirmed)
            let close = try await handle.close()
            #expect(close.terminalConfirmed)
        }
    }

    @Test("Withdrawing after a stop fails closed and the terminal sweep already requeued the row")
    func withdrawAfterStopFailsClosedWithRowRequeued() async throws {
        try await withSelfCoreFixture { fixture in
            let steerText = "guidance parked across a stop"
            let steerID = UUID()
            let (provider, adapter) = fixture.makeProvider(
                scripts: [[]],
                keepStreamOpen: true
            )
            let handle = try await fixture.runtime.startSession(
                fixture.newConversationRequest(goal: "Stop before a demote ask"),
                provider: provider
            )
            let running = await eventually {
                let snapshot = await handle.snapshot()
                return snapshot?.stateName == "streamingModel" && adapter.requests.count == 1
            }
            try #require(running)
            let store = try await fixture.runtime.runningInputStore()

            #expect(try await handle.steer(
                text: steerText,
                inputID: steerID,
                expectedConversationID: handle.identity.conversationID,
                expectedRunID: handle.identity.runID,
                executionMode: "agent"
            ))
            let cancel = await handle.cancelAndWait(timeout: 15)
            #expect(cancel.status == .stopped)
            #expect(cancel.terminal?.confirmed == true)

            // The confirmed terminal restored exactly the original queued row.
            let queued = try await store.pending(conversationID: handle.identity.conversationID)
            #expect(queued.count == 1)
            let recovered = try #require(queued.first { $0.id == steerID })
            #expect(recovered.status == .queued)
            #expect(recovered.content == steerText)
            #expect(recovered.selectedModelID == provider.model.id)
            #expect(recovered.executionMode == "agent")

            // A finished session never demotes; the honest queued row stays.
            #expect(await handle.withdrawSteer(id: steerID) == false)
            let stillQueued = try #require(await store.input(id: steerID))
            #expect(stillQueued.status == .queued)
            #expect(stillQueued.content == steerText)

            let close = try await handle.close()
            #expect(close.terminalConfirmed)
        }
    }

    @Test("Demoting goal-mode guidance preserves the goal run binding")
    func withdrawGoalGuidancePreservesGoalBinding() async throws {
        try await withSelfCoreFixture { fixture in
            let steerText = "goal guidance to demote"
            let steerID = UUID()
            let (provider, adapter) = fixture.makeProvider(
                scripts: [[
                    .textDelta(.init(text: "First answer.")),
                    .completed(.init(stopReason: .endTurn)),
                ]],
                holdFirstEvent: true
            )
            let handle = try await fixture.runtime.startSession(
                fixture.newConversationRequest(goal: "Demote goal guidance"),
                provider: provider
            )
            let running = await eventually {
                let snapshot = await handle.snapshot()
                return snapshot?.stateName == "streamingModel" && adapter.requests.count == 1
            }
            try #require(running)
            let store = try await fixture.runtime.runningInputStore()

            #expect(try await handle.steer(
                text: steerText,
                inputID: steerID,
                expectedConversationID: handle.identity.conversationID,
                expectedRunID: handle.identity.runID,
                executionMode: "goal"
            ))
            #expect(await handle.withdrawSteer(id: steerID))
            let demoted = try #require(await store.input(id: steerID))
            #expect(demoted.status == .queued)
            #expect(demoted.executionMode == "goal")
            // restoreQueued keeps the goal target binding so a later
            // startNextQueued can prove goal linkage again; an ordinary row
            // would have been cleared back to nil.
            #expect(demoted.targetRunID == handle.identity.runID)
            #expect(demoted.content == steerText)
            #expect(demoted.selectedModelID == provider.model.id)

            await adapter.openGate()
            let terminal = try #require(await handle.waitForTerminal(timeout: 15))
            #expect(terminal.confirmed)
            let close = try await handle.close()
            #expect(close.terminalConfirmed)
        }
    }
}
