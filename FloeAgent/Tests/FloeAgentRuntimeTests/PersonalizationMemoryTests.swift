import Foundation
import Testing
import GRDB
@testable import FloeAgentRuntime
@testable import FloePersistence

@Suite("FloeAgentRuntime.PersonalizationMemory")
struct PersonalizationMemoryTests {
    private struct FixedGenerator: PersonalizationGenerator {
        let content: String
        func generate(_ request: PersonalizationGenerationRequest) async throws
            -> PersonalizationGenerationResult {
            PersonalizationGenerationResult(content: content, evidenceDigest: "fixed")
        }
    }

    @Test("cosine similarity rejects incompatible spaces")
    func vectorMath() {
        #expect(MemoryVectorMath.cosineSimilarity([1, 0], [1, 0]) == 1)
        #expect(MemoryVectorMath.cosineSimilarity([1, 0], [0, 1]) == 0)
        #expect(MemoryVectorMath.cosineSimilarity([1], [1, 2]) == nil)
        #expect(MemoryVectorMath.cosineSimilarity([], []) == nil)
    }

    @Test("low-frequency cadence requires both elapsed time and activity")
    func cadence() {
        let cadence = PersonalizationUpdateCadence()
        let now = Date(timeIntervalSince1970: 2_000_000)
        var cursor = PersonalizationUpdateCursor(kind: .userProfile,
            lastGeneratedAt: now.addingTimeInterval(-8 * 86_400),
            completedRunsSinceUpdate: 9, userMessagesSinceUpdate: 29)
        #expect(!cadence.isDue(cursor, now: now))
        cursor.completedRunsSinceUpdate = 10
        #expect(cadence.isDue(cursor, now: now))
        cursor.lastGeneratedAt = now.addingTimeInterval(-86_400)
        #expect(!cadence.isDue(cursor, now: now))
    }

    @Test("documents are immutable revisions and rollback creates a new revision")
    func revisionsAndRollback() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let documentStore = SQLitePersonalizationStore(database: database)
        let memoryStore = SQLiteIntelligenceStore(database: database)
        let service = PersonalizationService(documents: documentStore, memories: memoryStore)

        let first = try await service.saveManual(kind: .soul, content: "first")
        let second = try await service.saveManual(kind: .soul, content: "second")
        let restored = try await service.rollback(to: first.revision, kind: .soul)
        #expect(first.revision == 1)
        #expect(second.revision == 2)
        #expect(restored.revision == 3)
        #expect(restored.content == "first")
        #expect(restored.source == .rollback)
        #expect(try await documentStore.activeDocument(kind: .soul, workspaceID: nil)?.id == restored.id)
    }

    @Test("one-click profile uses reviewed active memories and resets cadence")
    func oneClickProfile() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let documentStore = SQLitePersonalizationStore(database: database)
        let memoryStore = SQLiteIntelligenceStore(database: database)
        try await memoryStore.saveMemory(MemoryEntry(scope: .userProfile, status: .active,
            content: "Prefers concise Chinese answers", confidence: 1, importance: 1,
            sourceKind: .explicitUserRequest), evidence: [])
        let service = PersonalizationService(documents: documentStore, memories: memoryStore)
        try await service.recordActivity(completedRuns: 12, userMessages: 40)
        let document = try await service.generateNow(kind: .userProfile)
        #expect(document.content.contains("Prefers concise Chinese answers"))
        let cursor = try await documentStore.cursor(kind: .userProfile, workspaceID: nil)
        #expect(cursor.completedRunsSinceUpdate == 0)
        #expect(cursor.userMessagesSinceUpdate == 0)
        #expect(cursor.lastGeneratedAt != nil)
    }

    @Test("large automatic profile rewrites remain inactive until confirmed")
    func automaticLargeChangeRequiresReview() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let documentStore = SQLitePersonalizationStore(database: database)
        let memoryStore = SQLiteIntelligenceStore(database: database)
        let service = PersonalizationService(documents: documentStore, memories: memoryStore)
        let current = try await service.saveManual(kind: .userProfile, content: "# Profile\n- concise")
        try await service.recordActivity(completedRuns: 10)
        let draft = try #require(try await service.generateIfDue(kind: .userProfile,
            generator: FixedGenerator(content: String(repeating: "new profile detail\n", count: 80))))
        #expect(!draft.isActive)
        #expect(try await documentStore.activeDocument(kind: .userProfile, workspaceID: nil)?.id == current.id)
    }

    @Test("hybrid recall combines lexical and semantic results")
    func hybridRecall() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteIntelligenceStore(database: database)
        let apple = MemoryEntry(scope: .userProfile, status: .active,
            content: "apple fruit preference", confidence: 1, importance: 0.7,
            sourceKind: .explicitUserRequest)
        let banana = MemoryEntry(scope: .userProfile, status: .active,
            content: "banana smoothie", confidence: 1, importance: 0.7,
            sourceKind: .explicitUserRequest)
        try await store.saveMemory(apple, evidence: [])
        try await store.saveMemory(banana, evidence: [])
        try await store.saveEmbedding(MemoryEmbedding(memoryID: apple.id, modality: .text,
            modelIdentifier: "test", modelRevision: "1", values: [1, 0], contentDigest: "a"))
        try await store.saveEmbedding(MemoryEmbedding(memoryID: banana.id, modality: .text,
            modelIdentifier: "test", modelRevision: "1", values: [0, 1], contentDigest: "b"))
        let results = try await store.hybridRecall(HybridMemoryRecallRequest(
            query: "banana", queryEmbedding: [1, 0], modelIdentifier: "test",
            modelRevision: "1", limit: 2
        ))
        #expect(results.count == 2)
        #expect(Set(results.map(\.id)) == Set([apple.id, banana.id]))
        #expect(results.contains { $0.id == banana.id && $0.lexicalRank != nil })
        #expect(results.contains { $0.id == apple.id && $0.semanticRank != nil })
    }

    @Test("Deleted-task memory keeps ownership, crosses tasks, and is reinforced on recall")
    func deletedTaskMemoryLifecycle() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversations = SQLiteConversationStore(database: database)
        let store = SQLiteIntelligenceStore(database: database)
        let sourceTaskID = UUID()
        let otherTaskID = UUID()
        try await conversations.saveConversation(.init(
            id: sourceTaskID,
            title: "Source research",
            createdAt: Date(),
            updatedAt: Date()
        ))
        let memory = MemoryEntry(
            scope: .task(sourceTaskID),
            status: .active,
            content: "Use the violet release checklist",
            confidence: 1,
            importance: 0.7,
            sourceKind: .explicitUserRequest
        )
        try await store.saveMemory(memory, evidence: [])
        try await store.preserveMemoriesBeforeConversationDeletion(
            conversationID: sourceTaskID,
            ownerLabel: "Source research"
        )
        try await conversations.deleteConversation(id: sourceTaskID)

        let owned = try await store.memories(scope: .task(sourceTaskID), status: .active)
        #expect(owned.map(\.id) == [memory.id])
        let recalled = try await store.hybridRecall(.init(
            query: "violet release",
            conversationID: otherTaskID,
            limit: 6
        ))
        #expect(recalled.contains { $0.id == memory.id })
        let reinforcement: (Int, String?) = try await database.reader { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT recall_count, last_recalled_at FROM memory_entries WHERE id = ?",
                arguments: [memory.id.uuidString]
            ) else { return (-1, nil) }
            return (row["recall_count"], row["last_recalled_at"])
        }
        #expect(reinforcement.0 == 1)
        #expect(reinforcement.1 != nil)
    }

    @Test("Cross-task memory retains its originating task ID independently of scope")
    func globalMemoryTaskProvenance() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteIntelligenceStore(database: database)
        let taskID = UUID()
        let memory = MemoryEntry(
            scope: .userProfile,
            status: .active,
            content: "Prefer concise release evidence",
            confidence: 1,
            importance: 0.8,
            sourceKind: .automaticTurnReview,
            originConversationID: taskID
        )
        try await store.saveMemory(memory, evidence: [])

        let restored = try #require(
            try await store.memories(scope: .userProfile, status: .active).first
        )
        #expect(restored.originConversationID == taskID)
        let storedOrigin: String? = try await database.reader { db in
            try String.fetchOne(
                db,
                sql: "SELECT origin_conversation_id FROM memory_entries WHERE id = ?",
                arguments: [memory.id.uuidString]
            )
        }
        #expect(storedOrigin == taskID.uuidString)
    }

    @Test("Live task and workspace memories are not evicted by size")
    func liveOwnerMemoryCapacity() {
        let policy = MemoryCapacityPolicy(
            userProfileCharacters: 10,
            agentGlobalCharacters: 10,
            workspaceCharacters: 10,
            taskCharacters: 10
        )
        #expect(policy.activeCharacterLimit(for: .workspace(UUID())) == Int.max)
        #expect(policy.activeCharacterLimit(for: .task(UUID())) == Int.max)
        #expect(policy.activeCharacterLimit(for: .userProfile) == 10)
    }

    @Test("Batch memory deletion records every tombstone in one operation")
    func batchMemoryDeletion() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteIntelligenceStore(database: database)
        let first = MemoryEntry(scope: .userProfile, status: .active,
            content: "First batch memory", confidence: 1, importance: 0.5,
            sourceKind: .explicitUserRequest)
        let second = MemoryEntry(scope: .userProfile, status: .active,
            content: "Second batch memory", confidence: 1, importance: 0.5,
            sourceKind: .explicitUserRequest)
        try await store.saveMemory(first, evidence: [])
        try await store.saveMemory(second, evidence: [])

        try await store.deleteMemories(ids: [first.id, second.id], syncRevision: 7)

        #expect(try await store.memories(scope: .userProfile, status: .active).isEmpty)
        let tombstones = try await database.reader { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM memory_tombstones
                WHERE sync_revision = 7 AND memory_id IN (?, ?)
                """, arguments: [first.id.uuidString, second.id.uuidString]) ?? 0
        }
        #expect(tombstones == 2)
    }

    @Test("sensitive and conflicting candidates require confirmation")
    func candidateReview() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let documents = SQLitePersonalizationStore(database: database)
        let memories = SQLiteIntelligenceStore(database: database)
        let pipeline = MemoryCandidatePipeline(documents: documents, memories: memories)
        let candidate = MemoryCandidate(scope: .userProfile, content: "User lives in Sydney",
            confidence: 1, stability: 1, importance: 1, sensitivity: .personal,
            origin: .automaticTurnReview,
            evidence: [MemoryEvidenceReference(messageID: UUID(), excerpt: "I live in Sydney")])
        let record = try await pipeline.submit(candidate)
        #expect(record.status == .pending)
        #expect(try await documents.candidates(status: .pending).map(\.id) == [candidate.id])
    }

    @Test("only explicit user image attachments can become candidates")
    func imageGate() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let documents = SQLitePersonalizationStore(database: database)
        let memories = SQLiteIntelligenceStore(database: database)
        let pipeline = MemoryCandidatePipeline(documents: documents, memories: memories)
        let input = UserAttachedImageMemoryInput(attachmentID: UUID(), mimeType: "image/jpeg",
            extractedText: "", proposedMemory: "A preference", wasAttachedByUser: false)
        await #expect(throws: (any Error).self) {
            try await pipeline.submitUserAttachedImage(input, scope: .userProfile,
                evidenceMessageID: UUID(), sensitivity: .none,
                confidence: 1, stability: 1, importance: 1)
        }
    }
}
