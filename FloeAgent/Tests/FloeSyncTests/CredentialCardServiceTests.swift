import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
@testable import FloeSync

private final class FakeCardSecretStore: VaultSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var lockedAccounts: Set<String> = []

    func lockAccount(_ account: String) {
        lock.lock(); lockedAccounts.insert(account); lock.unlock()
    }
    func hasSecret(account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return items[account] != nil
    }

    func store(account: String, secret: Data) throws {
        lock.lock(); items[account] = secret; lock.unlock()
    }

    func read(account: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if lockedAccounts.contains(account) { throw KeychainStoreError.interactionNotAllowed }
        guard let data = items[account] else { throw KeychainStoreError.itemNotFound }
        return data
    }

    func delete(account: String) throws {
        lock.lock(); items.removeValue(forKey: account); lock.unlock()
    }
}

private struct CredentialCardFixture {
    let database: DatabaseManager
    let skills: SQLiteSkillStore
    let records: CredentialStore
    let local: FakeCardSecretStore
    let synchronized: FakeCardSecretStore
    let deviceBound: FakeCardSecretStore
    let vault: CredentialVaultService
    let configuration: SkillConfigurationStore
    let service: CredentialCardService
    let preferencesSuite: String

    static func make() async throws -> CredentialCardFixture {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let skills = SQLiteSkillStore(database: database)
        let records = CredentialStore(database: database)
        let local = FakeCardSecretStore()
        let synchronized = FakeCardSecretStore()
        let deviceBound = FakeCardSecretStore()
        let suite = "org.floeagent.tests.credential-card.\(UUID().uuidString)"
        let vault = CredentialVaultService(
            records: records,
            local: local,
            synchronized: synchronized,
            deviceBound: deviceBound,
            preferencesSuite: suite
        )
        let configuration = SkillConfigurationStore(database: database)
        return CredentialCardFixture(
            database: database,
            skills: skills,
            records: records,
            local: local,
            synchronized: synchronized,
            deviceBound: deviceBound,
            vault: vault,
            configuration: configuration,
            service: CredentialCardService(
                records: records,
                vault: vault,
                skillConfigurationStore: configuration
            ),
            preferencesSuite: suite
        )
    }

    func cleanup() {
        UserDefaults(suiteName: preferencesSuite)?
            .removePersistentDomain(forName: preferencesSuite)
    }

    func normalize(
        _ arguments: [String: Any],
        runID: UUID,
        toolName: String = CredentialCardService.toolName
    ) async throws -> [String: Any] {
        let input = try JSONSerialization.data(withJSONObject: arguments)
        let normalized = try await CredentialArgumentNormalizer.normalize(
            input,
            toolName: toolName,
            vault: vault,
            authority: RunCredentialAuthority(
                runID: runID,
                toolName: toolName,
                targetScope: .local
            )
        )
        return try #require(
            JSONSerialization.jsonObject(with: normalized) as? [String: Any]
        )
    }
}

@Suite("Credential card service")
struct CredentialCardServiceTests {
    @Test("Create consumes a normalized capture instead of storing its text")
    func createConsumesCapture() async throws {
        let fixture = try await CredentialCardFixture.make()
        defer { fixture.cleanup() }
        let runID = UUID()
        let raw = "one-time-\(UUID().uuidString)"
        let normalized = try await fixture.normalize([
            "action": "create",
            "label": "Bridge",
            "kind": "vncPassword",
            "secret": raw
        ], runID: runID)
        let placeholder = try #require(normalized["secret"] as? String)
        let captureID = try #require(SecretIngressScanner.credentialID(from: placeholder))
        #expect(try await fixture.records.record(id: captureID) != nil)

        let mutation = try await fixture.service.create(
            CredentialCardCreateInput(
                label: "Bridge",
                kind: .vncPassword,
                secret: placeholder
            ),
            runID: runID
        )
        #expect(mutation.id == captureID)
        let record = try #require(try await fixture.records.record(id: captureID))
        #expect(record.owner == .vault)
        #expect(record.kind == .vncPassword)
        #expect(record.label == "Bridge")
        #expect(record.origin == CredentialCardService.toolName)
        #expect(try await fixture.vault.resolveForApprovedUse(
            CredentialHandle(id: captureID)
        ) == Data(raw.utf8))
        #expect(try await fixture.records.cards(owner: .vault).count == 1)
        #expect(try await fixture.records.record(id: captureID)?.origin != nil)
    }

    @Test("Update consumes a normalized capture and replaces the target secret")
    func updateConsumesCapture() async throws {
        let fixture = try await CredentialCardFixture.make()
        defer { fixture.cleanup() }
        let runID = UUID()
        let old = "old-\(UUID().uuidString)"
        let target = try await fixture.service.create(
            CredentialCardCreateInput(label: "Target", kind: .genericToken, secret: old),
            runID: runID
        )
        let newValue = "new-\(UUID().uuidString)"
        let normalized = try await fixture.normalize([
            "action": "update",
            "id": target.id.uuidString,
            "secret": newValue
        ], runID: runID)
        let placeholder = try #require(normalized["secret"] as? String)
        let captureID = try #require(SecretIngressScanner.credentialID(from: placeholder))

        let mutation = try await fixture.service.update(
            CredentialCardUpdateInput(id: target.id, secret: placeholder),
            runID: runID
        )
        #expect(mutation.changed.contains("secret"))
        #expect(try await fixture.vault.resolveForApprovedUse(
            CredentialHandle(id: target.id)
        ) == Data(newValue.utf8))
        #expect(try await fixture.records.record(id: captureID) == nil)
        #expect(try await fixture.records.cards(owner: .vault).count == 1)
    }

    @Test("A capture from another run is refused, never stored as a secret")
    func wrongRunReferenceRefused() async throws {
        let fixture = try await CredentialCardFixture.make()
        defer { fixture.cleanup() }
        let runID = UUID()
        let raw = "other-run-\(UUID().uuidString)"
        let normalized = try await fixture.normalize([
            "action": "create",
            "label": "Other",
            "kind": "genericToken",
            "secret": raw
        ], runID: runID)
        let placeholder = try #require(normalized["secret"] as? String)
        let captureID = try #require(SecretIngressScanner.credentialID(from: placeholder))

        await #expect(throws: CredentialCardError.unauthorizedReference) {
            _ = try await fixture.service.create(
                CredentialCardCreateInput(label: "Stolen", kind: .genericToken, secret: placeholder),
                runID: UUID()
            )
        }
        let cards = try await fixture.records.cards(owner: .vault)
        #expect(cards.count == 1)
        #expect(cards.first?.id == captureID)
        let capture = try #require(try await fixture.records.record(id: captureID))
        #expect(capture.origin?.contains("credential.manage") == true)
        #expect(try await fixture.vault.resolveForApprovedUse(
            CredentialHandle(id: captureID)
        ) == Data(raw.utf8))
    }

    @Test("An existing card reference is not copied into another card")
    func existingCardReferenceRejected() async throws {
        let fixture = try await CredentialCardFixture.make()
        defer { fixture.cleanup() }
        let runID = UUID()
        let source = try await fixture.service.create(
            CredentialCardCreateInput(
                label: "Source",
                kind: .genericToken,
                secret: "source-\(UUID().uuidString)"
            ),
            runID: runID
        )
        let target = try await fixture.service.create(
            CredentialCardCreateInput(
                label: "Target",
                kind: .genericToken,
                secret: "target-\(UUID().uuidString)"
            ),
            runID: runID
        )
        let reference = CapturedSecret.placeholder(for: source.id)
        await #expect(throws: CredentialCardError.unauthorizedReference) {
            _ = try await fixture.service.update(
                CredentialCardUpdateInput(id: target.id, secret: reference),
                runID: runID
            )
        }
        #expect(try await fixture.records.cards(owner: .vault).count == 2)
    }

    @Test("Task-owned credentials are never mutated by card management")
    func taskOwnedTargetsRejected() async throws {
        let fixture = try await CredentialCardFixture.make()
        defer { fixture.cleanup() }
        let conversationID = UUID()
        try await SQLiteConversationStore(database: fixture.database).saveConversation(
            ConversationRecord(id: conversationID, title: "Test", createdAt: Date(), updatedAt: Date())
        )
        let taskCredential = CredentialRecord(
            kind: .genericToken,
            owner: .conversation(conversationID),
            origin: "chat-ingress",
            label: "Task secret"
        )
        try await fixture.records.save(taskCredential)
        await #expect(throws: CredentialCardError.notVaultOwned) {
            _ = try await fixture.service.update(
                CredentialCardUpdateInput(id: taskCredential.id, label: "renamed"),
                runID: UUID()
            )
        }
        await #expect(throws: CredentialCardError.notVaultOwned) {
            try await fixture.service.delete(id: taskCredential.id)
        }
        #expect(try await fixture.records.record(id: taskCredential.id) != nil)
        #expect(try await fixture.service.list().isEmpty)
    }

    @Test("Skill-bound credentials are protected from replacement and deletion")
    func skillBoundCredentialProtected() async throws {
        let fixture = try await CredentialCardFixture.make()
        defer { fixture.cleanup() }
        try await fixture.skills.save(PersistedSkill(
            id: "alpha",
            name: "alpha",
            version: "1.0.0",
            skillMarkdown: "body",
            manifestJSON: "{}",
            sourceURL: "floe-folder://local/alpha",
            rewrittenDigest: "digest"
        ))
        let card = try await fixture.service.create(
            CredentialCardCreateInput(
                label: "Bound",
                kind: .genericToken,
                secret: "bound-\(UUID().uuidString)"
            ),
            runID: UUID()
        )
        _ = try await fixture.configuration.saveVariables(
            skillID: "alpha",
            values: ["endpoint": "https://example.invalid"]
        )
        _ = try await fixture.configuration.bind(
            skillID: "alpha",
            fieldKey: "token",
            kind: .secret,
            connectionKind: nil,
            credentialID: card.id,
            role: .shared
        )
        #expect(try await fixture.service.list().isEmpty)
        await #expect(throws: CredentialCardError.credentialInUse) {
            _ = try await fixture.service.update(
                CredentialCardUpdateInput(id: card.id, label: "renamed"),
                runID: UUID()
            )
        }
        await #expect(throws: CredentialCardError.credentialInUse) {
            try await fixture.service.delete(id: card.id)
        }
        #expect(try await fixture.records.record(id: card.id) != nil)
    }

    @Test("Locked capture is not adopted and nothing is deleted")
    func lockedCaptureRejected() async throws {
        let fixture = try await CredentialCardFixture.make()
        defer { fixture.cleanup() }
        let runID = UUID()
        let normalized = try await fixture.normalize([
            "action": "create",
            "label": "Locked",
            "kind": "genericToken",
            "secret": "locked-\(UUID().uuidString)"
        ], runID: runID)
        let placeholder = try #require(normalized["secret"] as? String)
        let captureID = try #require(SecretIngressScanner.credentialID(from: placeholder))
        let capture = try #require(try await fixture.records.record(id: captureID))
        fixture.local.lockAccount(capture.keychainAccount)

        await #expect(throws: (any Error).self) {
            _ = try await fixture.service.create(
                CredentialCardCreateInput(label: "Locked", kind: .genericToken, secret: placeholder),
                runID: runID
            )
        }
        #expect(try await fixture.records.record(id: captureID) != nil)
        #expect(try await fixture.records.cards(owner: .vault).count == 1)
    }
}
