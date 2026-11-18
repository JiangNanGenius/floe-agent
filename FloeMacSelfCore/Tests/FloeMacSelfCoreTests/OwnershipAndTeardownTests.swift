// SPDX-License-Identifier: MPL-2.0
//
// Ownership and teardown tests: one live session per conversation, exact-run
// cancellation fences, durable terminal read-back, and shutdown that refuses
// to hide an unconfirmed run.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloeSecurity
import FloePersistence
import FloeAgentRuntime
@testable import FloeMacSelfCore

@Suite("Mac self-owned runtime ownership and teardown")
struct OwnershipAndTeardownTests {

    @Test("A cancel ignored while the runtime is idle is retried after dispatch starts")
    func cancellationBetweenDispatchAndRuntimeStart() async throws {
        try await withSelfCoreFixture { fixture in
            let entered = AsyncGate()
            let proceed = AsyncGate()
            let attemptedWhileIdle = AsyncGate()
            await fixture.runtime.setCancellationTestHooks(
                beforeServiceStart: {
                    await entered.open()
                    await proceed.wait()
                },
                afterCancellationAttempt: { await attemptedWhileIdle.open() }
            )
            let (provider, _) = fixture.makeProvider(
                scripts: [[.textDelta(.init(text: "Held")), .completed(.init(stopReason: .endTurn))]],
                holdFirstEvent: true
            )
            let handle = try await fixture.runtime.startSession(
                fixture.newConversationRequest(goal: "Cancel before runtime starts"), provider: provider
            )
            await entered.wait()
            let pendingCancel = Task { await handle.cancelAndWait(timeout: 10) }
            // The hook runs after the first cancel call returned while the
            // service start is held, proving that attempt met an idle runtime.
            await attemptedWhileIdle.wait()
            await proceed.open()
            let receipt = await pendingCancel.value
            #expect(receipt.status == .stopped)
            #expect(receipt.terminal?.confirmed == true)
            #expect(receipt.terminal?.outcome == .interrupted)
            #expect(try await handle.close().terminalConfirmed)
        }
    }

    @Test("One live run owns a conversation; a late close cannot release a newer run's claim")
    func conversationBusyAndClaimFence() async throws {
        try await withSelfCoreFixture { fixture in
            let conversationID = UUID()
            let (providerA, adapterA) = fixture.makeProvider(
                scripts: [[
                    .textDelta(.init(text: "A is still working.")),
                    .completed(.init(stopReason: .endTurn)),
                ]],
                holdFirstEvent: true
            )
            let requestA = FloeMacSelfSessionRequest(
                newConversationID: conversationID,
                goal: "First turn",
                context: FloeMacSelfRunContext(workspaceName: "Fixture"),
                chatFastMode: true
            )
            let handleA = try await fixture.runtime.startSession(requestA, provider: providerA)
            let dispatchedA = await eventually {
                let snapshot = await handleA.snapshot()
                return snapshot?.stateName == "streamingModel" && !adapterA.requests.isEmpty
            }
            // The session can report .running before the provider starts.
            // Wait for actual dispatch so cancellation exercises interruption.
            try #require(dispatchedA)

            let (providerBusy, _) = fixture.makeProvider(scripts: [])
            let busyRequest = fixture.continuationRequest(conversationID: conversationID, goal: "Second turn")
            let busyError = await selfCoreError {
                _ = try await fixture.runtime.startSession(busyRequest, provider: providerBusy)
            }
            #expect(busyError == .conversationBusy(conversationID))

            let inventory = try await fixture.runtime.nonTerminalRuns()
            #expect(inventory.contains { $0.id == handleA.identity.runID })

            let cancelA = await handleA.cancelAndWait(timeout: 10)
            #expect(cancelA.status == .stopped)
            let terminalA = try #require(cancelA.terminal)
            #expect(terminalA.confirmed)
            #expect(terminalA.outcome == .interrupted)
            #expect(terminalA.durableRunState == "checkpointed")

            let (providerB, adapterB) = fixture.makeProvider(
                scripts: [[
                    .textDelta(.init(text: "B is working.")),
                    .completed(.init(stopReason: .endTurn)),
                ]],
                holdFirstEvent: true
            )
            let requestB = fixture.continuationRequest(conversationID: conversationID, goal: "Second turn")
            let handleB = try await fixture.runtime.startSession(requestB, provider: providerB)
            let dispatchedB = await eventually {
                let snapshot = await handleB.snapshot()
                return snapshot?.stateName == "streamingModel" && !adapterB.requests.isEmpty
            }
            try #require(dispatchedB)

            // Closing the older terminal session must not release B's claim.
            _ = try await handleA.close()
            let (providerThird, _) = fixture.makeProvider(scripts: [])
            let thirdError = await selfCoreError {
                _ = try await fixture.runtime.startSession(
                    fixture.continuationRequest(conversationID: conversationID, goal: "Third turn"),
                    provider: providerThird
                )
            }
            #expect(thirdError == .conversationBusy(conversationID))

            let cancelB = await handleB.cancelAndWait(timeout: 10)
            #expect(cancelB.status == .stopped)
            #expect(cancelB.terminal?.confirmed == true)
            _ = try await handleB.close()

            let afterInventory = try await fixture.runtime.nonTerminalRuns()
            #expect(!afterInventory.contains { $0.id == handleA.identity.runID || $0.id == handleB.identity.runID })
        }
    }

    @Test("Active close and non-cancelling shutdown refuse, then a fenced cancel allows clean close")
    func closeAndShutdownFence() async throws {
        try await withSelfCoreFixture { fixture in
            let (provider, adapter) = fixture.makeProvider(
                scripts: [[
                    .textDelta(.init(text: "Held for ownership.")),
                    .completed(.init(stopReason: .endTurn)),
                ]],
                holdFirstEvent: true
            )
            let handle = try await fixture.runtime.startSession(
                fixture.newConversationRequest(goal: "Ownership fence"),
                provider: provider
            )
            let running = await eventually {
                let snapshot = await handle.snapshot()
                return snapshot?.stateName == "streamingModel" && !adapter.requests.isEmpty
            }
            try #require(running)

            let closeError = await selfCoreError {
                _ = try await handle.close()
            }
            #expect(closeError == .sessionNotFinished(handle.identity.runID))

            let shutdownError = await selfCoreError {
                _ = try await fixture.runtime.shutdown(cancelActive: false)
            }
            #expect(shutdownError == .activeSessions([handle.identity.runID]))

            // The failed shutdown must leave the runtime usable.
            let stillLive = await handle.snapshot()
            #expect(stillLive != nil)

            let cancel = await handle.cancelAndWait(timeout: 10)
            #expect(cancel.status == .stopped)
            #expect(cancel.terminal?.confirmed == true)
            #expect(cancel.terminal?.outcome == .interrupted)

            let close = try await handle.close()
            #expect(close.terminalConfirmed)
            #expect(close.preservedUnconfirmedRun == false)

            let shutdown = try await fixture.shutdown(cancelActive: false)
            #expect(shutdown.databaseClosed)
            #expect(shutdown.closedSessionCount == 0)

            let startAfterShutdown = await selfCoreError {
                _ = try await fixture.runtime.startSession(
                    fixture.newConversationRequest(goal: "Too late"),
                    provider: fixture.makeProvider(scripts: []).binding
                )
            }
            #expect(startAfterShutdown == .runtimeClosed)

            let readAfterShutdown = await selfCoreError {
                _ = try await fixture.runtime.runRecord(runID: handle.identity.runID)
            }
            #expect(readAfterShutdown == .runtimeClosed)

            let closeAfterShutdown = await selfCoreError {
                _ = try await handle.close()
            }
            #expect(closeAfterShutdown == .runtimeClosed)
        }
    }

    @Test("Cancellation during a pending approval expires the card and never executes the tool")
    func cancellationDuringApprovalFailsClosed() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Cancel approval workspace")
            let call = try SelfCoreFixture.fixtureCall(id: "call-cancel-approval")
            let (provider, _) = fixture.makeProvider(scripts: [
                [.toolRequest(call), .completed(.init(stopReason: .toolUse))],
                [.textDelta(.init(text: "unreachable")), .completed(.init(stopReason: .endTurn))],
            ])
            let (tools, executor, _) = try fixture.makeToolBinding(workspaceID: workspaceID)
            let handle = try await fixture.runtime.startSession(
                fixture.newConversationRequest(
                    goal: "Cancel while waiting",
                    workspaceID: workspaceID,
                    chatFastMode: false
                ),
                provider: provider,
                tools: tools
            )

            let waiting = await eventually {
                let snapshot = await handle.snapshot()
                return snapshot?.pendingApproval != nil
            }
            #expect(waiting)
            let snapshot = try #require(await handle.snapshot())
            let pending = try #require(snapshot.pendingApproval)

            let cancel = await handle.cancelAndWait(timeout: 10)
            #expect(cancel.status == .stopped)
            let terminal = try #require(cancel.terminal)
            #expect(terminal.confirmed)
            #expect(terminal.outcome == .interrupted)
            #expect(executor.executedCalls.isEmpty)

            let lateAllow = approvalCommand(
                handle: handle,
                pending: pending,
                decision: .allow(
                    scope: ApprovalScope(toolName: pending.toolCall.toolName, singleUse: true),
                    expiresAt: nil
                )
            )
            let lateResult = await handle.resolveApproval(lateAllow)
            #expect(lateResult == .rejected(.sessionEnded))

            let close = try await handle.close()
            #expect(close.terminalConfirmed)
        }
    }

    @Test("Shutdown with cancelActive stops a live run, confirms it, and closes the database")
    func shutdownCancelsActiveRun() async throws {
        try await withSelfCoreFixture { fixture in
            let (provider, _) = fixture.makeProvider(
                scripts: [[
                    .textDelta(.init(text: "Shutdown will stop this.")),
                    .completed(.init(stopReason: .endTurn)),
                ]],
                holdFirstEvent: true
            )
            let handle = try await fixture.runtime.startSession(
                fixture.newConversationRequest(goal: "Shutdown fence"),
                provider: provider
            )
            let running = await eventually {
                await handle.phase() == .running
            }
            #expect(running)

            let shutdown = try await fixture.shutdown(
                cancelActive: true,
                allowUnconfirmed: false,
                timeout: 10
            )
            #expect(shutdown.databaseClosed)
            #expect(shutdown.preservedRunIDs.isEmpty)
            let sessionAfterShutdown = await fixture.runtime.session(runID: handle.identity.runID)
            #expect(sessionAfterShutdown == nil)

            // The database is closed, so this must fail closed rather than
            // returning stale state.
            let readError = await selfCoreError {
                _ = try await fixture.runtime.runRecord(runID: handle.identity.runID)
            }
            #expect(readError == .runtimeClosed)
        }
    }
}
