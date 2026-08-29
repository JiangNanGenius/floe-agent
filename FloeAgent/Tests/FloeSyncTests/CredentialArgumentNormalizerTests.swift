import Foundation
import Testing
import FloePersistence
import FloeSecurity
import FloeModels
@testable import FloeSync

@Suite("Credential argument normalization")
struct CredentialArgumentNormalizerTests {
    @Test("Nested VNC plaintext becomes a reusable credential reference")
    func nestedVNCPassword() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let records = CredentialStore(database: database)
        let vault = CredentialVaultService(records: records)
        let rawPassword = "nested-vnc-secret-\(UUID().uuidString)"
        let hostID = UUID()
        try await RemoteHostStore(database: database).saveHost(
            id: hostID,
            displayName: "Lab host",
            address: "192.0.2.10",
            port: 22,
            user: "tester",
            authJSON: #"{"none":{}}"#,
            jumpChainJSON: "[]",
            hostKeyPolicy: "trustOnFirstUse",
            allowsLegacyAlgorithms: false,
            vncEndpointJSON: nil
        )
        let input = try JSONSerialization.data(withJSONObject: [
            "hostID": hostID.uuidString,
            "vncConnections": [[
                "displayName": "Direct VNC",
                "transport": "direct",
                "host": "192.0.2.10",
                "port": 5_900,
                "credentialInput": rawPassword
            ]]
        ])

        let output = try await CredentialArgumentNormalizer.normalize(
            input,
            toolName: "ssh.updateHost",
            vault: vault
        )
        let text = try #require(String(data: output, encoding: .utf8))
        #expect(!text.contains(rawPassword))

        let object = try #require(
            JSONSerialization.jsonObject(with: output) as? [String: Any]
        )
        let connections = try #require(object["vncConnections"] as? [[String: Any]])
        let placeholder = try #require(connections.first?["credentialInput"] as? String)
        let id = try #require(SecretIngressScanner.credentialID(from: placeholder))
        let record = try #require(try await records.record(id: id))
        #expect(record.kind == .vncPassword)
        #expect(record.hostID == hostID)
        #expect(record.label.contains("Direct VNC"))
        #expect(record.label.contains("192.0.2.10"))
        #expect(!record.label.contains(rawPassword))
        #expect(record.origin?.contains("ssh.updateHost") == true)
        #expect(try await vault.resolveForApprovedUse(CredentialHandle(id: id)) == Data(rawPassword.utf8))

        try await records.delete(id: id)
        await vault.drainDeletionQueue()
    }

    @Test("Existing references remain unchanged and create no duplicate card")
    func existingReferenceIsIdempotent() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let records = CredentialStore(database: database)
        let vault = CredentialVaultService(records: records)
        let id = UUID()
        let placeholder = CapturedSecret.placeholder(for: id)
        let input = try JSONSerialization.data(withJSONObject: ["credentialInput": placeholder])

        let output = try await CredentialArgumentNormalizer.normalize(
            input,
            toolName: "vnc.typeCredential",
            vault: vault
        )

        #expect(output == input)
        #expect(try await records.records().isEmpty)
    }

    @Test("A new host and its password can be captured in the same call")
    func newHostCredentialDoesNotRequireExistingForeignKey() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let records = CredentialStore(database: database)
        let vault = CredentialVaultService(records: records)
        let rawPassword = "new-host-secret-\(UUID().uuidString)"
        let input = try JSONSerialization.data(withJSONObject: [
            "hostID": UUID().uuidString,
            "displayName": "New VNC host",
            "host": "198.51.100.8",
            "credentialInput": rawPassword
        ])

        let output = try await CredentialArgumentNormalizer.normalize(
            input,
            toolName: "ssh.updateHost",
            vault: vault
        )
        let object = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let placeholder = try #require(object["credentialInput"] as? String)
        let id = try #require(SecretIngressScanner.credentialID(from: placeholder))
        let record = try #require(try await records.record(id: id))

        #expect(record.hostID == nil)
        #expect(record.label.contains("New VNC host"))
        #expect(!record.label.contains(rawPassword))
        #expect(try await vault.resolveForApprovedUse(CredentialHandle(id: id)) == Data(rawPassword.utf8))
    }

    @Test("Run authority binds credential capture to its tool and field")
    func authorityBinding() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let records = CredentialStore(database: database)
        let vault = CredentialVaultService(records: records)
        let input = try JSONSerialization.data(withJSONObject: [
            "credentialInput": "temporary-secret"
        ])
        let authority = RunCredentialAuthority(
            runID: UUID(),
            toolName: "ssh.updateHost",
            targetScope: .local,
            allowedFieldNames: ["credentialinput"]
        )

        await #expect(throws: (any Error).self) {
            _ = try await CredentialArgumentNormalizer.normalize(
                input,
                toolName: "vnc.typeCredential",
                vault: vault,
                authority: authority
            )
        }
        #expect(try await records.records().isEmpty)

        await #expect(throws: (any Error).self) {
            _ = try await CredentialArgumentNormalizer.normalize(
                input,
                toolName: "ssh.updateHost",
                targetScope: .host(UUID()),
                vault: vault,
                authority: authority
            )
        }
        #expect(try await records.records().isEmpty)
    }

    @Test("Secure card projection omits Keychain implementation details")
    func secureCardProjection() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let records = CredentialStore(database: database)
        let record = CredentialRecord(
            kind: .vncPassword,
            owner: .vault,
            label: "Lab VNC",
            keychainAccount: "private.keychain.account"
        )
        try await records.save(record)

        let card = try #require(try await records.cards().first)
        let encoded = try JSONEncoder().encode(card)
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(card.reference == "⟨credential:\(record.id.uuidString)⟩")
        #expect(!text.contains("private.keychain.account"))
    }
}
