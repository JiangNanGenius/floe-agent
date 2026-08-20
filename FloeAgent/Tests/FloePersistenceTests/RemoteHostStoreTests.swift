import Foundation
import Testing
@testable import FloePersistence

@Suite("FloePersistence.RemoteHostStore")
struct RemoteHostStoreTests {
    private func makeStore(hostID: UUID) async throws -> RemoteHostStore {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = RemoteHostStore(database: database)
        try await store.saveHost(
            id: hostID,
            displayName: "Test host",
            address: "target.internal",
            port: 22,
            user: "floe",
            authJSON: "{}",
            jumpChainJSON: "[]",
            hostKeyPolicy: "tofu",
            allowsLegacyAlgorithms: false,
            vncEndpointJSON: nil
        )
        return store
    }

    @Test("TOFU record persists and last-seen updates")
    func trustAndTouch() async throws {
        let hostID = UUID()
        let store = try await makeStore(hostID: hostID)
        let firstSeen = Date(timeIntervalSince1970: 1_700_000_000)
        let lastSeen = firstSeen.addingTimeInterval(60)
        let record = KnownHostRecord(
            hostID: hostID,
            address: "target.internal",
            port: 22,
            keyType: "ssh-ed25519",
            fingerprintSHA256: "SHA256:test",
            firstSeenAt: firstSeen,
            lastSeenAt: firstSeen
        )

        try await store.trust(record)
        try await store.touch(id: record.id, at: lastSeen)

        let loaded = try #require(await store.knownHost(
            address: record.address,
            port: record.port,
            keyType: record.keyType
        ))
        #expect(loaded.id == record.id)
        #expect(loaded.fingerprintSHA256 == record.fingerprintSHA256)
        #expect(loaded.lastSeenAt == lastSeen)
    }

    @Test("Trusting a replacement key updates the tuple")
    func replacementKey() async throws {
        let hostID = UUID()
        let store = try await makeStore(hostID: hostID)
        try await store.trust(KnownHostRecord(
            hostID: hostID,
            address: "target.internal",
            port: 22,
            keyType: "ssh-ed25519",
            fingerprintSHA256: "SHA256:first"
        ))
        try await store.trust(KnownHostRecord(
            hostID: hostID,
            address: "target.internal",
            port: 22,
            keyType: "ssh-ed25519",
            fingerprintSHA256: "SHA256:replacement"
        ))

        let loaded = try #require(await store.knownHost(
            address: "target.internal",
            port: 22,
            keyType: "ssh-ed25519"
        ))
        #expect(loaded.fingerprintSHA256 == "SHA256:replacement")
    }
}
