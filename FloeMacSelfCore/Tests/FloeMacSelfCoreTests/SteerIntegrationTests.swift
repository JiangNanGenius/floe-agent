// SPDX-License-Identifier: MPL-2.0
//
// Running user guidance (steer) behavior tests. The real runtime consumes an
// accepted steer at its next safe boundary; these tests prove, against the
// durable database and the recorded provider requests, that an accepted steer
// reaches the subsequent provider turn and appears exactly once in reopened
// history, that stale/ended targets are unaccepted without durable writes,
// that same-id replay is idempotent while active and false after terminal,
// and that a stop restores unconsumed guidance to one visible queued row with
// its original metadata. Every root is a unique 0700 temporary directory; no
// user database or credential is touched.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
import FloePersistence
import FloeAgentRuntime
import GRDB
@testable import FloeMacSelfCore

@Suite("Mac self-core running steer")
struct SteerIntegrationTests {

    @Test("Accepted steer reaches the next provider turn and reopened history exactly once")
    func acceptedSteerReachesNextTurnAndHistory() async throws {
        try await withSelfCoreFixture { fixture in
            let steerText = "Please also cover the Mac host integration."
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
            let request = fixture.newConversationRequest(goal: "Answer in two stages")
            let handle = try await fixture.runtime.startSession(request, provider: provider)
            let (collector, collectorTask) = startEventCollector(handle)
            defer { collectorTask.cancel() }

            let running = await eventually {
                let snapshot = await handle.snapshot()
                return snapshot?.stateName == "streamingModel" && adapter.requests.count == 1
            }
            try #require(running)

            // The pending row mirrors the iPad lifecycle before acceptance and
            // carries the original model/workspace/mode for later recovery.
            let store = try await fixture.runtime.runningInputStore()
            let accepted = try await handle.steer(
                text: steerText,
                inputID: steerID,
                expectedConversationID: handle.identity.conversationID,
                expectedRunID: handle.identity.runID
            )
            #expect(accepted)
            let promoted = try #require(await store.input(id: steerID))
            #expect(promoted.conversationID == handle.identity.conversationID)
            #expect(promoted.mode == .steer)
            #expect(promoted.status == .steerPending)
            #expect(promoted.targetRunID == handle.identity.runID)
            #expect(promoted.content == steerText)
            #expect(promoted.selectedModelID == provider.model.id)
            #expect(promoted.workspaceID == handle.identity.workspaceID)
            #expect(promoted.executionMode == "chat")

            // Same-id replay while the run is active is idempotent: the
            // durable row answers true and nothing is re-submitted.
            #expect(try await handle.steer(
                text: steerText,
                inputID: steerID,
                expectedConversationID: handle.identity.conversationID,
                expectedRunID: handle.identity.runID
            ))
            #expect(adapter.requests.count == 1)

            // A mismatched replay of the same id must fail closed.
            let mismatched = await selfCoreError {
                _ = try await handle.steer(
                    text: "different text, same id",
                    inputID: steerID,
                    expectedConversationID: handle.identity.conversationID,
                    expectedRunID: handle.identity.runID)
            }
            #expect(mismatched == .invalidRequest(
                "steer input identity is already bound to different content"))
            #expect(adapter.requests.count == 1)

            await adapter.openGate()
            let terminal = try #require(await handle.waitForTerminal(timeout: 15))
            #expect(terminal.confirmed)
            #expect(terminal.outcome == .completed)
            #expect(terminal.runID == handle.identity.runID)

            // The steer reached the subsequent provider turn.
            #expect(adapter.requests.count == 2)
            let secondRequest = try #require(adapter.requests.dropFirst().first)
            let secondUserMessages = secondRequest.messages.filter { $0.role == "user" }
            #expect(secondUserMessages.contains { $0.content == steerText })

            // Consumption was published once on the real event stream.
            let consumedEvent = await collector.harnessEvents().contains { event in
                if case .userInputConsumed(let receipt) = event {
                    return receipt.inputID == steerID && receipt.runID == handle.identity.runID
                }
                return false
            }
            #expect(consumedEvent)

            // Reopened durable history contains the steer text exactly once,
            // bound to this exact run, read through an independent connection.
            let reopened = try DatabaseManager(path: fixture.databaseURL)
            let steerRows: [(role: String, content: String, runID: String)] = try await reopened.reader { db in
                try Row.fetchAll(db, sql: """
                    SELECT role, content, run_id FROM messages
                    WHERE id = ? AND conversation_id = ?
                    """, arguments: [steerID.uuidString, handle.identity.conversationID.uuidString])
                    .map { row in
                        (
                            role: row["role"] as String,
                            content: row["content"] as String,
                            runID: row["run_id"] as String
                        )
                    }
            }
            try await reopened.close()
            #expect(steerRows.count == 1)
            #expect(steerRows.first?.role == "user")
            #expect(steerRows.first?.content == steerText)
            #expect(steerRows.first?.runID == handle.identity.runID.uuidString)

            // The pending row is the durable consumed receipt, and a replay
            // after the confirmed terminal correctly returns false.
            let consumed = try #require(await store.input(id: steerID))
            #expect(consumed.status == .consumed)
            #expect(consumed.consumedRunID == handle.identity.runID)
            #expect(consumed.consumedAt != nil)
            #expect(try await handle.steer(
                text: steerText,
                inputID: steerID,
                expectedConversationID: handle.identity.conversationID,
                expectedRunID: handle.identity.runID
            ) == false)
            let stillConsumed = try #require(await store.input(id: steerID))
            #expect(stillConsumed.status == .consumed)
            #expect(stillConsumed.consumedRunID == handle.identity.runID)

            let close = try await handle.close()
            #expect(close.terminalConfirmed)
        }
    }

    @Test("Steer with a stale conversation or run identity is unaccepted and writes nothing")
    func staleSteerIdentityIsUnaccepted() async throws {
        try await withSelfCoreFixture { fixture in
            let staleText = "stale target guidance"
            let (provider, adapter) = fixture.makeProvider(
                scripts: [[
                    .textDelta(.init(text: "Terminal answer.")),
                    .completed(.init(stopReason: .endTurn)),
                ]],
                holdFirstEvent: true
            )
            let handle = try await fixture.runtime.startSession(
                fixture.newConversationRequest(goal: "Stale steer target"),
                provider: provider
            )
            let running = await eventually {
                let snapshot = await handle.snapshot()
                return snapshot?.stateName == "streamingModel" && adapter.requests.count == 1
            }
            try #require(running)
            let store = try await fixture.runtime.runningInputStore()

            // A run id the host no longer owns must not be steered.
            #expect(try await handle.steer(
                text: staleText,
                inputID: UUID(),
                expectedConversationID: handle.identity.conversationID,
                expectedRunID: UUID()
            ) == false)
            // A conversation id from another projection must not be steered.
            #expect(try await handle.steer(
                text: staleText,
                inputID: UUID(),
                expectedConversationID: UUID(),
                expectedRunID: handle.identity.runID
            ) == false)

            // Nothing durable was written: no pending row, no transcript text.
            #expect(try await store.pending(conversationID: handle.identity.conversationID).isEmpty)
            let messages = try await fixture.runtime.conversationMessages(
                conversationID: handle.identity.conversationID)
            #expect(!messages.contains { $0.content == staleText })

            await adapter.openGate()
            let terminal = try #require(await handle.waitForTerminal(timeout: 15))
            #expect(terminal.confirmed)
            _ = try await handle.close()
        }
    }

    @Test("Steer is unaccepted once the run ended")
    func endedRunRejectsSteer() async throws {
        try await withSelfCoreFixture { fixture in
            let (provider, adapter) = fixture.makeProvider(scripts: [[
                .textDelta(.init(text: "Terminal answer.")),
                .completed(.init(stopReason: .endTurn)),
            ]])
            let handle = try await fixture.runtime.startSession(
                fixture.newConversationRequest(goal: "End before guidance"),
                provider: provider
            )
            let terminal = try #require(await handle.waitForTerminal(timeout: 15))
            #expect(terminal.confirmed)
            let store = try await fixture.runtime.runningInputStore()

            // The host projection can lag the terminal; the unaccepted text
            // stays recoverable and nothing enters the durable transcript.
            #expect(try await handle.steer(
                text: "too late",
                inputID: UUID(),
                expectedConversationID: handle.identity.conversationID,
                expectedRunID: handle.identity.runID
            ) == false)
            #expect(try await store.pending(conversationID: handle.identity.conversationID).isEmpty)
            let messages = try await fixture.runtime.conversationMessages(
                conversationID: handle.identity.conversationID)
            #expect(!messages.contains { $0.content == "too late" })

            // The runtime itself refused, so the scripted provider saw exactly
            // the prepared user turn and nothing more.
            #expect(adapter.requests.count == 1)
            _ = try await handle.close()
        }
    }

    @Test("A stop restores unconsumed guidance to one visible queued row with original metadata")
    func stopRestoresUnconsumedSteerToQueue() async throws {
        try await withSelfCoreFixture { fixture in
            let steerText = "guidance that arrived before the stop"
            let steerID = UUID()
            let (provider, adapter) = fixture.makeProvider(
                scripts: [[]],
                keepStreamOpen: true
            )
            let handle = try await fixture.runtime.startSession(
                fixture.newConversationRequest(goal: "Stop before consumption"),
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
            let preStopRow = try await store.input(id: steerID)
            #expect(preStopRow?.status == .steerPending)

            // A new guidance attempt after the stop is unaccepted.
            let cancel = await handle.cancelAndWait(timeout: 15)
            #expect(cancel.status == .stopped)
            #expect(cancel.terminal?.confirmed == true)
            #expect(try await handle.steer(
                text: "after stop",
                inputID: UUID(),
                expectedConversationID: handle.identity.conversationID,
                expectedRunID: handle.identity.runID
            ) == false)

            // Non-consumption persistence: the accepted guidance never became
            // a transcript entry, and the confirmed terminal restored exactly
            // one visible queued row, ready for host recovery in this same
            // app session, with its original metadata intact.
            let messages = try await fixture.runtime.conversationMessages(
                conversationID: handle.identity.conversationID)
            #expect(!messages.contains { $0.id == steerID })
            #expect(!messages.contains { $0.content == steerText })

            let queued = try await store.pending(conversationID: handle.identity.conversationID)
            #expect(queued.count == 1)
            let recovered = try #require(queued.first { $0.id == steerID })
            #expect(recovered.status == .queued)
            #expect(recovered.mode == .queue)
            #expect(recovered.targetRunID == nil)
            #expect(recovered.consumedRunID == nil)
            #expect(recovered.content == steerText)
            #expect(recovered.selectedModelID == provider.model.id)
            #expect(recovered.workspaceID == handle.identity.workspaceID)
            #expect(recovered.executionMode == "chat")

            let close = try await handle.close()
            #expect(close.terminalConfirmed)
        }
    }

    @Test("Invalid steer text throws before any durable write or runtime call")
    func invalidSteerTextThrows() async throws {
        try await withSelfCoreFixture { fixture in
            let (provider, adapter) = fixture.makeProvider(
                scripts: [[
                    .textDelta(.init(text: "Terminal answer.")),
                    .completed(.init(stopReason: .endTurn)),
                ]],
                holdFirstEvent: true
            )
            let handle = try await fixture.runtime.startSession(
                fixture.newConversationRequest(goal: "Validate guidance input"),
                provider: provider
            )
            let running = await eventually {
                let snapshot = await handle.snapshot()
                return snapshot?.stateName == "streamingModel" && adapter.requests.count == 1
            }
            try #require(running)

            let empty = await selfCoreError {
                _ = try await handle.steer(
                    text: "   \n\t", inputID: UUID(),
                    expectedConversationID: handle.identity.conversationID,
                    expectedRunID: handle.identity.runID)
            }
            #expect(empty == .invalidRequest("steer text must not be empty"))
            let nul = await selfCoreError {
                _ = try await handle.steer(
                    text: "hello\0world", inputID: UUID(),
                    expectedConversationID: handle.identity.conversationID,
                    expectedRunID: handle.identity.runID)
            }
            #expect(nul == .invalidRequest("steer text must not contain NUL"))
            let invalidMode = await selfCoreError {
                _ = try await handle.steer(
                    text: "valid text", inputID: UUID(),
                    expectedConversationID: handle.identity.conversationID,
                    expectedRunID: handle.identity.runID,
                    executionMode: "  ")
            }
            #expect(invalidMode == .invalidRequest("steer execution mode is invalid"))

            let store = try await fixture.runtime.runningInputStore()
            #expect(try await store.pending(conversationID: handle.identity.conversationID).isEmpty)
            #expect(adapter.requests.count == 1)

            await adapter.openGate()
            let terminal = try #require(await handle.waitForTerminal(timeout: 15))
            #expect(terminal.confirmed)
            _ = try await handle.close()
        }
    }
}
