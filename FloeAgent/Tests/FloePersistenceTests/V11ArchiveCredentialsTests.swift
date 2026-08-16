import Foundation
import Testing
@testable import FloePersistence
import GRDB

@Suite("V11 archive and credential ownership")
struct V11ArchiveCredentialsTests {
    private func database() async throws -> DatabaseManager {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-v11-\(UUID().uuidString).sqlite")
        let database = try DatabaseManager(path: url)
        try await database.migrate()
        return database
    }

    @Test("Archived tasks are hidden by default and restorable")
    func archiveProjection() async throws {
        let database = try await database()
        let store = SQLiteConversationStore(database: database)
        let now = Date()
        let conversation = ConversationRecord(id: UUID(), title: "Archive me", createdAt: now, updatedAt: now)
        try await store.saveConversation(conversation)
        try await store.setArchived(id: conversation.id, archived: true)
        #expect(try await store.conversations().isEmpty)
        #expect(try await store.conversations(includeArchived: true).count == 1)
        try await store.setArchived(id: conversation.id, archived: false)
        #expect(try await store.conversations().map(\.id) == [conversation.id])
    }

    @Test("Deleting an owner stages Keychain cleanup and keeps vault credentials")
    func ownerCascadeQueuesDeletion() async throws {
        let database = try await database()
        let conversationStore = SQLiteConversationStore(database: database)
        let credentialStore = CredentialStore(database: database)
        let now = Date()
        let conversation = ConversationRecord(id: UUID(), title: "Scoped", createdAt: now, updatedAt: now)
        try await conversationStore.saveConversation(conversation)
        let scoped = CredentialRecord(
            kind: .genericToken, owner: .conversation(conversation.id),
            label: "temporary", keychainAccount: "test.scoped"
        )
        let vault = CredentialRecord(
            kind: .websitePassword, owner: .vault,
            label: "saved", keychainAccount: "test.vault"
        )
        try await credentialStore.save(scoped)
        try await credentialStore.save(vault)
        try await conversationStore.deleteConversation(id: conversation.id)

        #expect(try await credentialStore.record(id: scoped.id) == nil)
        #expect(try await credentialStore.record(id: vault.id) != nil)
        #expect(try await credentialStore.pendingDeletions().contains {
            $0.keychainAccount == "test.scoped" && !$0.synchronizable
        })
    }

    @Test("Credential ownership constraint rejects ambiguous metadata")
    func ownershipConstraint() async throws {
        let database = try await database()
        await #expect(throws: (any Error).self) {
            try await database.writer { db in
                try db.execute(sql: """
                    INSERT INTO credential_records (
                        id, kind, owner_kind, label, keychain_account,
                        synchronizable, device_bound, created_at, updated_at
                    ) VALUES ('bad', 'genericToken', 'conversation', 'bad',
                              'bad.account', 0, 0, '2026-01-01T00:00:00Z',
                              '2026-01-01T00:00:00Z')
                    """)
            }
        }
    }
}
