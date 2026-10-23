import Foundation
import Testing
import FloeCore
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

    /// Bug-1 regression driven through the REAL status path (`batchCompletionStatus()`
    /// → `credentialSyncStatus()`), the same computation the fetch/send epilogues
    /// write into `status`. A device-bound vault descriptor registered with
    /// `synchronizable == true` (the exact shape RemoteSessionCenter.loadHosts
    /// produces for a Floe-generated SSH key while saved-credential sync is on)
    /// must not freeze the iCloud delivery status, because its secret never
    /// enters the synced Keychain namespace by design and
    /// setSavedCredentialSyncEnabled deliberately skips it — the old
    /// unconditional deviceBound branch returned `.waitingForSecret` with no
    /// recovery path. Records that genuinely await cloud delivery (a
    /// non-device-bound synchronized vault item, or a provider secret ref)
    /// must still wait.
    @Test("Batch completion status excludes device-bound descriptors only")
    func deviceBoundDescriptorDoesNotBlockCloudDeliveryStatus() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let credentials = CredentialStore(database: database)
        let metadata = ConfigSyncMetadataStore(database: database)
        let configuration = ModelConfigurationStore(database: database)
        let engine = ConfigSyncEngine(
            configurationStore: configuration,
            metadataStore: metadata,
            credentialStore: credentials
        )

        // Existing seam: credentialSyncStatus() reads the device-local sync
        // switches from standard defaults. Restore whatever the host had.
        let previousPreferences = SyncControlPreferences.load()
        defer { previousPreferences.save() }
        SyncControlPreferences(
            overallEnabled: true,
            configurationEnabled: true,
            savedCredentialsEnabled: true
        ).save()

        let generatedKey = CredentialRecord(
            kind: .sshPrivateKey, owner: .vault, label: "Floe-generated host key",
            synchronizable: true, deviceBound: true
        )
        try await engine.saveCredentialDescriptor(generatedKey)
        // Without the fix this is `.waitingForSecret` forever: the synced
        // namespace can never contain a device-bound secret.
        #expect(await engine.batchCompletionStatus() == .synced)

        // Honest waiting is preserved inside the same loop: a vault record
        // that really is expected to arrive via iCloud Keychain but has not
        // yet still reports the wait.
        let pendingPassphrase = CredentialRecord(
            kind: .sshPassword, owner: .vault, label: "Imported passphrase",
            synchronizable: true
        )
        try await engine.saveCredentialDescriptor(pendingPassphrase)
        #expect(await engine.batchCompletionStatus() == .waitingForSecret)
        try await engine.deleteCredentialDescriptor(id: pendingPassphrase.id)
        #expect(await engine.batchCompletionStatus() == .synced)

        // The provider branch is untouched (Bug-2 local fallback deliberately
        // NOT implemented): a synchronized secret ref that has not arrived
        // still waits even though a runtime read could fall back to local.
        let provider = ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://sync-audit.test/v1")!,
            secretRef: SecretReference(
                keychainAccount: "provider.\(UUID().uuidString)",
                synchronizable: true
            )
        )
        try await configuration.saveProvider(provider)
        #expect(await engine.batchCompletionStatus() == .waitingForSecret)
    }
}
