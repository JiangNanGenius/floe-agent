// FloePersistenceTests — create-only Linux cleanup purpose row.

import Foundation
import Testing
import GRDB
import FloeCore
import FloeModels
@testable import FloePersistence

@Suite("Linux cache cleanup task store")
struct LinuxCacheCleanupTaskStoreTests {
    private func makeDatabase() async throws -> DatabaseManager {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return database
    }

    private func insertConversation(_ database: DatabaseManager, id: UUID) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try await database.writer { db in
            try db.execute(
                sql: "INSERT INTO conversations(id,title,created_at,updated_at) VALUES(?,'Cleanup',?,?)",
                arguments: [id.uuidString, now, now]
            )
        }
    }

    @Test("Profile persists exactly and an ordinary conversation has no cleanup row")
    func createAndRead() async throws {
        let database = try await makeDatabase()
        let conversationID = UUID()
        try await insertConversation(database, id: conversationID)
        let store = LinuxCacheCleanupTaskStore(database: database)
        let profile = LinuxCacheCleanupTaskProfile(
            conversationID: conversationID,
            environmentID: "shared",
            runtimeGeneration: "runtime-generation-1"
        )
        let saved = try await store.create(profile)
        #expect(saved.conversationID == conversationID)
        #expect(saved.environmentID == "shared")
        #expect(saved.backend == .linuxVM)
        #expect(saved.runtimeGeneration == "runtime-generation-1")
        #expect(try await store.profile(conversationID: UUID()) == nil)
        #expect(try await store.isCleanupConversation(conversationID))
    }

    @Test("A conflicting second writer cannot broaden or rebind the purpose")
    func firstWriterWins() async throws {
        let database = try await makeDatabase()
        let conversationID = UUID()
        try await insertConversation(database, id: conversationID)
        let store = LinuxCacheCleanupTaskStore(database: database)
        _ = try await store.create(LinuxCacheCleanupTaskProfile(
            conversationID: conversationID,
            environmentID: "shared"
        ))
        var failed = false
        do {
            _ = try await store.create(LinuxCacheCleanupTaskProfile(
                conversationID: conversationID,
                environmentID: "project-1"
            ))
        } catch {
            failed = true
        }
        #expect(failed)
        let saved = try await store.profile(conversationID: conversationID)
        #expect(saved?.environmentID == "shared")
    }

    @Test("Invalid purpose rows are refused before persistence")
    func invalidProfileRefused() async throws {
        let database = try await makeDatabase()
        let conversationID = UUID()
        try await insertConversation(database, id: conversationID)
        let store = LinuxCacheCleanupTaskStore(database: database)
        var failures = 0
        for candidate in [
            LinuxCacheCleanupTaskProfile(conversationID: conversationID, environmentID: ""),
            LinuxCacheCleanupTaskProfile(conversationID: conversationID, environmentID: "shared", backend: .macBridge),
            LinuxCacheCleanupTaskProfile(conversationID: conversationID, environmentID: "shared", profile: "other.v1")
        ] {
            do { _ = try await store.create(candidate) } catch { failures += 1 }
        }
        #expect(failures == 3)
        #expect(try await store.profile(conversationID: conversationID) == nil)
    }

    @Test("Conversation deletion cascades the purpose row")
    func cascade() async throws {
        let database = try await makeDatabase()
        let conversationID = UUID()
        try await insertConversation(database, id: conversationID)
        let store = LinuxCacheCleanupTaskStore(database: database)
        _ = try await store.create(LinuxCacheCleanupTaskProfile(
            conversationID: conversationID,
            environmentID: "shared"
        ))
        try await database.writer { db in
            try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [conversationID.uuidString])
        }
        #expect(try await store.profile(conversationID: conversationID) == nil)
    }

    @Test("Ordinary row, workspace and cleanup profile are published in one transaction")
    func atomicCreationIncludesPurposeBeforePublication() async throws {
        let database = try await makeDatabase()
        let record = ConversationRecord(id: UUID(), title: "Cleanup", createdAt: Date(), updatedAt: Date())
        let profile = LinuxCacheCleanupTaskProfile(conversationID: record.id, environmentID: "shared")
        let conversations = SQLiteConversationStore(database: database)
        try await conversations.saveConversationWithCanonicalWorkspace(record, cleanupProfile: profile)
        let reopened = SQLiteConversationStore(database: database)
        #expect(try await reopened.conversation(id: record.id) != nil)
        let saved = try await LinuxCacheCleanupTaskStore(database: database).profile(conversationID: record.id)
        #expect(saved?.environmentID == "shared")
        #expect(saved?.runtimeGeneration == nil) // unknown until actual runtime evidence
        let owners = try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation_workspace_ownership WHERE conversation_id = ?",
                             arguments: [record.id.uuidString])
        }
        #expect(owners == 1)
    }

    @Test("A profile-write failure rolls back conversation and canonical workspace")
    func atomicCreationRollsBackOnPurposeFailure() async throws {
        let database = try await makeDatabase()
        try await database.writer { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_cleanup_profile BEFORE INSERT ON linux_cache_cleanup_tasks
                BEGIN SELECT RAISE(ABORT, 'fixture purpose write failure'); END;
                """)
        }
        let record = ConversationRecord(id: UUID(), title: "Cleanup", createdAt: Date(), updatedAt: Date())
        do {
            try await SQLiteConversationStore(database: database).saveConversationWithCanonicalWorkspace(
                record, cleanupProfile: .init(conversationID: record.id, environmentID: "shared"))
            Issue.record("Purpose write failure must abort publication")
        } catch { }
        #expect(try await SQLiteConversationStore(database: database).conversation(id: record.id) == nil)
        let counts = try await database.reader { db in
            try ["workspaces", "conversation_workspace_ownership", "linux_cache_cleanup_tasks"].map { table in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
            }
        }
        #expect(counts == [0, 0, 0])
    }

    @Test("Profile decode failure throws; only an absent row means an ordinary chat")
    func corruptPurposeDoesNotBecomeOrdinary() async throws {
        let database = try await makeDatabase()
        let record = ConversationRecord(id: UUID(), title: "Cleanup", createdAt: Date(), updatedAt: Date())
        try await SQLiteConversationStore(database: database).saveConversationWithCanonicalWorkspace(
            record, cleanupProfile: .init(conversationID: record.id, environmentID: "shared"))
        try await database.writer { db in
            try db.execute(sql: "UPDATE linux_cache_cleanup_tasks SET created_at = 'not-a-date' WHERE conversation_id = ?",
                           arguments: [record.id.uuidString])
        }
        let store = LinuxCacheCleanupTaskStore(database: database)
        do {
            _ = try await store.profile(conversationID: record.id)
            Issue.record("Unreadable purpose must fail closed, not return nil")
        } catch { }
        do {
            _ = try await store.isCleanupConversation(record.id)
            Issue.record("Authorization projection must preserve the read error")
        } catch { }
        #expect(try await store.profile(conversationID: UUID()) == nil)
    }

}
