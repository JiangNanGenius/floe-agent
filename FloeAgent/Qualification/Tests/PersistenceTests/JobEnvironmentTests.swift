import Foundation
import Testing
import FloePersistence

@Suite("Job environment persistence")
struct JobEnvironmentTests {
    @Test func migrationPersistsEnvironmentAndKeepsIdempotentOwner() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.migrate()
        let conversation = UUID(), run = UUID()
        let now = ISO8601DateFormatter().string(from: Date())
        try await db.writer { db in
            try db.execute(sql: "INSERT INTO conversations (id, title, created_at, updated_at) VALUES (?, 'test', ?, ?)", arguments: [conversation.uuidString, now, now])
            try db.execute(sql: "INSERT INTO runs (id, conversation_id, state, goal, started_at) VALUES (?, ?, 'running', 'test', ?)", arguments: [run.uuidString, conversation.uuidString, now])
        }
        let store = BackgroundJobStore(database: db)
        let saved = try await store.submit(BackgroundJob(conversationID: conversation, runID: run, toolCallID: "same-call", kind: .tool, targetTool: "exec.shell", payloadJSON: Data("{}".utf8), environmentID: "environment-a"))
        let replay = try await store.submit(BackgroundJob(conversationID: conversation, runID: run, toolCallID: "same-call", kind: .tool, targetTool: "exec.shell", payloadJSON: Data("{}".utf8), environmentID: "environment-b"))
        #expect(saved.environmentID == "environment-a")
        #expect(replay.id == saved.id)
        #expect(replay.environmentID == "environment-a")
        let running = try await store.transition(id: saved.id, to: .running)
        #expect(running.environmentID == "environment-a")
    }
}
