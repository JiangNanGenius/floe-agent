import Foundation
import Testing
@testable import FloePersistence

@Suite("FloePersistence.ConfigSyncMetadataStore")
struct ConfigSyncMetadataStoreTests {
    private func makeStore() async throws -> ConfigSyncMetadataStore {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return ConfigSyncMetadataStore(database: database)
    }

    @Test("Metadata and pending action round-trip")
    func metadataRoundTrip() async throws {
        let store = try await makeStore()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = ConfigSyncMetadata(
            recordType: "ProviderProfile",
            recordID: UUID().uuidString,
            fieldTimestamps: ["baseURL": timestamp],
            cloudChangeTag: "tag-1",
            pendingAction: .save,
            updatedAt: timestamp
        )

        try await store.save(metadata)

        #expect(try await store.metadata(recordType: metadata.recordType, recordID: metadata.recordID) == metadata)
        #expect(try await store.pending() == [metadata])
    }

    @Test("Engine state replaces atomically")
    func engineStateRoundTrip() async throws {
        let store = try await makeStore()
        try await store.saveEngineState(Data([1, 2, 3]))
        try await store.saveEngineState(Data([4, 5]))
        #expect(try await store.engineState() == Data([4, 5]))
    }
}
