// SPDX-License-Identifier: MPL-2.0
// Real self-core runtime with an isolated database and scripted provider.
import Foundation
import Testing
import GRDB
import FloePersistence
import FloeAgentRuntime
@testable import FloeMacSelfCore

@Suite("Prepared input and provider boundary")
struct PreparedInputIntegrationTests {
    @Test("A truncated run preserves its partial answer and releases the ended admission")
    func limitedRealRuntimePreservesOutput() async throws {
        try await withSelfCoreFixture { fixture in
            let (provider, _) = fixture.makeProvider(scripts: [[
                .textDelta(.init(text: "Partial synthetic answer")),
                .completed(.init(stopReason: .maxTokens)),
            ]])
            let handle = try await fixture.runtime.startSession(
                FloeMacSelfSessionRequest(goal: "Synthetic limited run"), provider: provider)
            let receipt = try #require(await handle.waitForTerminal(timeout: 15))
            #expect(receipt.confirmed)
            #expect(receipt.outcome == .unknown)
            #expect(receipt.completionStopReason == .maxTokens)
            #expect(receipt.finalMessageVerified)
            let rows = try await fixture.runtime.conversationMessages(conversationID: handle.identity.conversationID)
            #expect(rows.contains { $0.role == "assistant" && $0.content == "Partial synthetic answer" })
            let closed = try await handle.close()
            #expect(closed.terminalConfirmed)
            let (nextProvider, _) = fixture.makeProvider(scripts: [[
                .textDelta(.init(text: "Next synthetic answer")),
                .completed(.init(stopReason: .endTurn)),
            ]])
            let next = try await fixture.runtime.startSession(
                FloeMacSelfSessionRequest(conversationID: handle.identity.conversationID, goal: "Continue"),
                provider: nextProvider)
            let nextReceipt = try #require(await next.waitForTerminal(timeout: 15))
            #expect(nextReceipt.confirmed)
            #expect(nextReceipt.outcome == .completed)
            _ = try await next.close()
        }
    }

    @Test("The provider receives exactly the committed trimmed user message")
    func canonicalGoalMatchesDurableInput() async throws {
        try await withSelfCoreFixture { fixture in
            let (provider, adapter) = fixture.makeProvider(scripts: [[
                .textDelta(.init(text: "Synthetic reply")),
                .completed(.init(stopReason: .endTurn)),
            ]])
            let handle = try await fixture.runtime.startSession(
                FloeMacSelfSessionRequest(goal: " \n  你好，Floe  \t\n"), provider: provider)
            let terminal = try #require(await handle.waitForTerminal(timeout: 15))
            #expect(terminal.confirmed)
            let messages = try await fixture.runtime.conversationMessages(conversationID: handle.identity.conversationID)
            let input = try #require(messages.first { $0.id == handle.identity.userMessageID })
            #expect(input.content == "你好，Floe")
            let request = try #require(adapter.requests.first)
            let user = try #require(request.messages.last { $0.role == "user" })
            #expect(Array(user.content.utf8) == Array(input.content.utf8))
            let database = try DatabaseManager(path: fixture.databaseURL)
            let actual = try await database.reader { db in
                try Data.fetchOne(db, sql: "SELECT CAST(content AS BLOB) FROM messages WHERE id = ?", arguments: [handle.identity.userMessageID.uuidString])
            }
            #expect(actual == Data(input.content.utf8))
            try await database.close()
            _ = try await handle.close()
        }
    }

    @Test("NUL in a goal or title is rejected before admission and provider call")
    func nulIsRejectedBeforeAnyRun() async throws {
        try await withSelfCoreFixture { fixture in
            let (provider, adapter) = fixture.makeProvider(scripts: [])
            for (goal, title) in [("hello\0world", "ok"), ("hello", "title\0suffix")] {
                let conversation = UUID(), run = UUID()
                let error = await selfCoreError {
                    _ = try await fixture.runtime.startSession(
                        FloeMacSelfSessionRequest(newConversationID: conversation, conversationTitle: title, goal: goal, runID: run), provider: provider)
                }
                #expect(error == .invalidRequest("the goal and title must not contain NUL"))
                let admission = try await fixture.runtime.admissionRecord(conversationID: conversation)
                let persistedRun = try await fixture.runtime.runRecord(runID: run)
                #expect(admission == nil)
                #expect(persistedRun == nil)
            }
            #expect(adapter.requests.isEmpty)
        }
    }

    @Test("Input changed after preparation cannot reach the provider")
    func changedDurableInputRefusesDispatch() async throws {
        try await withSelfCoreFixture { fixture in
            let entered = AsyncGate(), proceed = AsyncGate()
            await fixture.runtime.setPreparedInputTestHook {
                await entered.open()
                await proceed.wait()
            }
            let (provider, adapter) = fixture.makeProvider(scripts: [])
            let handle = try await fixture.runtime.startSession(
                FloeMacSelfSessionRequest(goal: "original fixture input"), provider: provider)
            await entered.wait()
            let database = try DatabaseManager(path: fixture.databaseURL)
            try await database.writer { db in
                try db.execute(sql: "UPDATE messages SET content = ? WHERE id = ?",
                               arguments: ["synthetic changed input", handle.identity.userMessageID.uuidString])
            }
            try await database.close()
            await proceed.open()
            let receipt = try #require(await handle.waitForTerminal(timeout: 15))
            #expect(receipt.outcome == .abortedBeforeDispatch)
            #expect(adapter.requests.isEmpty)
            _ = try await handle.close()
        }
    }
}
