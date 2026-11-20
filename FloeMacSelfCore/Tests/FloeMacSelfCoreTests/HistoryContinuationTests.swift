// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeAgentRuntime
import FloePersistence
@testable import FloeMacSelfCore

@Suite("Mac history continuation")
struct HistoryContinuationTests {
    @Test("Reopen committed history, keep original evidence and protect uncertain effects")
    func reopenHistoryContinuation() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Fixture workspace")
            _ = try await fixture.shutdown(cancelActive: false)
            let database = try DatabaseManager(path: fixture.databaseURL)
            let conversations = SQLiteConversationStore(database: database)
            let workspaces = SQLiteWorkspaceStore(database: database)
            let runs = SQLiteRunStore(database: database)
            let checkpoints = SQLiteRunCheckpointStore(database: database, legacyDirectory: nil)
            let now = Date()
            func seed(state: String, mode: ConversationMode, uncertain: Bool = false, hasOwner: Bool = true) async throws -> RunRecord {
                let id = UUID()
                try await conversations.saveConversation(.init(id: id, title: "Fixture", createdAt: now, updatedAt: now))
                if hasOwner { try await workspaces.assignConversation(workspaceID: workspaceID, conversationID: id) }
                let run = RunRecord(id: UUID(), conversationID: id, state: state, goal: "Original request", startedAt: now,
                                    endedAt: now, conversationMode: mode.rawValue)
                try await runs.saveRun(run)
                try await conversations.appendMessage(.init(id: UUID(), conversationID: id,
                                                            role: "user", content: run.goal, createdAt: now, runID: run.id))
                try await conversations.appendMessage(.init(id: UUID(), conversationID: id,
                                                            role: "assistant", content: "Saved partial result", createdAt: now, runID: run.id))
                var checkpoint = AgentCheckpoint(runID: run.id, conversationID: id, state: .preparing(.init(goal: run.goal, resumedFromCheckpoint: false)),
                                                 messages: [], conversationMode: mode)
                checkpoint.toolAccess = .task
                if uncertain {
                    checkpoint.toolLifecycleEntries = [.init(callID: "old-write", toolName: "fixture.write",
                                                              isSideEffecting: true, phase: .dispatched)]
                }
                try await checkpoints.save(checkpoint)
                return run
            }
            let failed = try await seed(state: "failed", mode: .chat)
            let completed = try await seed(state: "completed", mode: .chat)
            let uncertain = try await seed(state: "interrupted", mode: .chat, uncertain: true)
            let goal = try await seed(state: "failed", mode: .goal)
            let ownerless = try await seed(state: "failed", mode: .chat, hasOwner: false)
            try await database.close()
            let reopened = try FloeMacSelfRuntime(databaseURL: fixture.databaseURL, owner: fixture.owner,
                                                  provenance: makeHostProvenance(databaseURL: fixture.databaseURL))
            do {
                _ = try await reopened.bootstrap()
                #expect(try await reopened.historyContinuationAccess(after: failed.id, in: failed.conversationID) == .task)
                #expect(try await reopened.historyContinuationAccess(after: completed.id, in: completed.conversationID) == nil)
                #expect(try await reopened.historyContinuationAccess(after: uncertain.id, in: uncertain.conversationID) == .chat)
                #expect(try await reopened.historyContinuationAccess(after: goal.id, in: goal.conversationID) == nil)
                #expect(try await reopened.historyContinuationAccess(after: ownerless.id, in: ownerless.conversationID) == nil)
                #expect(try await reopened.historyContinuationAccess(after: failed.id, in: uncertain.conversationID) == nil)
                #expect(try await reopened.recentRuns(conversationID: uncertain.conversationID).map(\.id) == [uncertain.id])
                #expect(try await reopened.recoveryPoint(runID: uncertain.id)?.toolLifecycleEntries?.first?.phase == .dispatched)
                let (provider, adapter) = fixture.makeProvider(scripts: [[.textDelta(.init(text: "New result")), .completed(.init(stopReason: .endTurn))]])
                #expect(adapter.requests.isEmpty)
                let handle = try await reopened.startSession(.init(conversationID: failed.conversationID, goal: "Continue from saved progress"),
                                                             provider: provider)
                let receipt = try #require(await handle.waitForTerminal(timeout: 10))
                #expect(receipt.confirmed && receipt.outcome == .completed)
                _ = try await handle.close()
                let transcript = try await reopened.conversationMessages(conversationID: failed.conversationID)
                #expect(transcript.filter { $0.content == failed.goal }.count == 1)
                #expect(transcript.contains { $0.runID == failed.id && $0.content == "Saved partial result" })
                #expect(transcript.contains { $0.runID == handle.identity.runID && $0.content == "New result" })
                #expect(adapter.requests.count == 1)
                #expect(adapter.requests.first?.messages.contains { $0.content == "Saved partial result" } == true)
                #expect(try await reopened.historyContinuationAccess(after: failed.id, in: failed.conversationID) == nil)
            } catch {
                _ = try await reopened.shutdown(cancelActive: true)
                throw error
            }
            _ = try await reopened.shutdown(cancelActive: false)
        }
    }
}
