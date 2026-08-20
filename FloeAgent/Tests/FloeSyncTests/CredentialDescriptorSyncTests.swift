import Foundation
import Testing
@testable import FloeSync
@testable import FloePersistence

@Suite("Credential descriptor sync")
struct CredentialDescriptorSyncTests {
    @Test("Only synchronizable vault metadata is queued for CloudKit")
    func vaultOnly() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let credentials = CredentialStore(database: database)
        let metadata = ConfigSyncMetadataStore(database: database)
        let engine = ConfigSyncEngine(
            metadataStore: metadata,
            credentialStore: credentials
        )

        let temporary = CredentialRecord(
            kind: .genericToken,
            owner: .conversation(UUID()),
            label: "temporary",
            synchronizable: false
        )
        await #expect(throws: Error.self) {
            try await engine.saveCredentialDescriptor(temporary)
        }

        let vault = CredentialRecord(
            kind: .websitePassword,
            owner: .vault,
            origin: "https://example.test",
            label: "Example",
            synchronizable: true
        )
        try await engine.saveCredentialDescriptor(vault)
        let saved = try #require(try await credentials.record(id: vault.id))
        #expect(saved.id == vault.id)
        #expect(saved.kind == vault.kind)
        #expect(saved.owner == .vault)
        #expect(saved.origin == vault.origin)
        #expect(saved.keychainAccount == vault.keychainAccount)
        #expect(saved.synchronizable)
        let pending = try #require(try await metadata.metadata(
            recordType: ConfigSyncRecordType.credentialDescriptor.rawValue,
            recordID: vault.id.uuidString
        ))
        #expect(pending.pendingAction == .save)
    }

    @Test("Unpublishing keeps local vault metadata")
    func unpublishKeepsLocalRecord() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let credentials = CredentialStore(database: database)
        let metadata = ConfigSyncMetadataStore(database: database)
        let engine = ConfigSyncEngine(metadataStore: metadata, credentialStore: credentials)
        let vault = CredentialRecord(
            kind: .sshPassword, owner: .vault, label: "Host",
            synchronizable: true
        )
        try await engine.saveCredentialDescriptor(vault)
        try await engine.unpublishCredentialDescriptor(id: vault.id)

        #expect(try await credentials.record(id: vault.id) != nil)
        let tombstone = try #require(try await metadata.metadata(
            recordType: ConfigSyncRecordType.credentialDescriptor.rawValue,
            recordID: vault.id.uuidString
        ))
        #expect(tombstone.pendingAction == .delete)
    }
}
