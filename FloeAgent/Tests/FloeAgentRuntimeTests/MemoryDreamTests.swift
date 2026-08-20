import Foundation
import Testing
import GRDB
import FloeCore
import FloePersistence
@testable import FloeAgentRuntime

@Suite("FloeAgentRuntime.MemoryDream")
struct MemoryDreamTests {

    @Test("explicit reject disposition wins even with high scores")
    func rejectDisposition() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.migrate()
        let pipeline = MemoryCandidatePipeline(
            documents: SQLitePersonalizationStore(database: db),
            memories: SQLiteIntelligenceStore(database: db)
        )
        let candidate = Self.candidate(content: "looks durable", confidence: 0.99)
        let record = try await pipeline.submit(candidate, modelDisposition: .reject(reason: "model said drop"))
        #expect(record.status == .rejected)
    }

    @Test("activate verdict cannot override the low-confidence floor")
    func activateButLowConfidence() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.migrate()
        let pipeline = MemoryCandidatePipeline(
            documents: SQLitePersonalizationStore(database: db),
            memories: SQLiteIntelligenceStore(database: db)
        )
        let candidate = Self.candidate(content: "fleeting", confidence: 0.1, stability: 0.1, importance: 0.1)
        let record = try await pipeline.submit(candidate, modelDisposition: .activate)
        #expect(record.status == .rejected)
    }

    @Test("activate verdict with high scores activates the memory")
    func activateHighScores() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.migrate()
        let messageID = try await Self.insertEvidenceMessage(db)
        let memories = SQLiteIntelligenceStore(database: db)
        let pipeline = MemoryCandidatePipeline(
            documents: SQLitePersonalizationStore(database: db),
            memories: memories
        )
        let candidate = Self.candidate(
            content: "User prefers dark mode",
            confidence: 0.95, stability: 0.9, importance: 0.9,
            evidenceMessageID: messageID
        )
        let record = try await pipeline.submit(candidate, modelDisposition: .activate)
        #expect(record.status == .activated)
        let active = try await memories.memories(scope: .agentGlobal, status: .active)
        #expect(active.contains { $0.content == "User prefers dark mode" })
    }

    @Test("personal sensitivity always parks for review")
    func personalParks() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.migrate()
        let pipeline = MemoryCandidatePipeline(
            documents: SQLitePersonalizationStore(database: db),
            memories: SQLiteIntelligenceStore(database: db)
        )
        let candidate = Self.candidate(content: "lives at 123 Main St", confidence: 0.99, sensitivity: .personal)
        let record = try await pipeline.submit(candidate, modelDisposition: .activate)
        #expect(record.status == .pending)
    }

    @Test("candidate persistence stores an evidence digest, never the raw excerpt")
    func evidenceIsDigested() async throws {
        let db = try DatabaseManager.inMemory()
        try await db.migrate()
        let documents = SQLitePersonalizationStore(database: db)
        let pipeline = MemoryCandidatePipeline(
            documents: documents,
            memories: SQLiteIntelligenceStore(database: db)
        )
        let secret = "api_key=must-not-reach-sqlite"
        let candidate = MemoryCandidate(
            scope: .agentGlobal,
            content: "A harmless rejected candidate",
            confidence: 0.1,
            stability: 0.1,
            importance: 0.1,
            origin: .automaticTurnReview,
            evidence: [MemoryEvidenceReference(messageID: UUID(), excerpt: secret)]
        )

        _ = try await pipeline.submit(candidate, modelDisposition: .reject(reason: "drop"))
        let stored = try #require(try await documents.candidates().first)
        #expect(stored.candidate.evidence.first?.excerpt.hasPrefix("sha256:") == true)
        #expect(stored.candidate.evidence.first?.excerpt.contains(secret) == false)
    }

    private static func candidate(
        content: String,
        confidence: Double = 0.9,
        stability: Double = 0.9,
        importance: Double = 0.9,
        sensitivity: MemorySensitivity = .none,
        evidenceMessageID: UUID = UUID()
    ) -> MemoryCandidate {
        MemoryCandidate(
            scope: .agentGlobal,
            content: content,
            confidence: confidence,
            stability: stability,
            importance: importance,
            sensitivity: sensitivity,
            origin: .automaticTurnReview,
            evidence: [MemoryEvidenceReference(messageID: evidenceMessageID, excerpt: "evidence")]
        )
    }

    private static func insertEvidenceMessage(_ db: DatabaseManager) async throws -> UUID {
        let conversationID = UUID()
        let messageID = UUID()
        let now = ISO8601DateFormatter().string(from: Date())
        try await db.writer { db in
            try db.execute(
                sql: "INSERT INTO conversations (id, title, created_at, updated_at) VALUES (?, '', ?, ?)",
                arguments: [conversationID.uuidString, now, now]
            )
            try db.execute(
                sql: "INSERT INTO messages (id, conversation_id, role, content, created_at) VALUES (?, ?, 'user', ?, ?)",
                arguments: [messageID.uuidString, conversationID.uuidString, "evidence", now]
            )
        }
        return messageID
    }
}
