import Foundation
import Testing
import GRDB
@testable import FloePersistence

@Suite("Skill configuration store")
struct SkillConfigurationStoreTests {
    private let official = [
        SkillOfficialSource(
            owner: "JiangNanGenius",
            repository: "floe-agent",
            publisher: "JiangNanGenius"
        )
    ]

    private func makeStore(
        officialSources: [SkillOfficialSource]? = nil
    ) async throws -> (DatabaseManager, SQLiteSkillStore, SkillConfigurationStore) {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let skills = SQLiteSkillStore(database: database)
        let store = SkillConfigurationStore(
            database: database,
            officialSources: officialSources ?? official
        )
        return (database, skills, store)
    }

    private func saveSkill(
        _ store: SQLiteSkillStore,
        id: String = "alpha",
        sourceURL: String?,
        version: String = "1.0.0",
        rewrittenDigest: String = "digest-1",
        sourceDigest: String? = "source-1",
        rewriteModelID: String? = "reviewed-1"
    ) async throws {
        try await store.save(PersistedSkill(
            id: id,
            name: id,
            version: version,
            skillMarkdown: "body",
            manifestJSON: "{}",
            sourceURL: sourceURL,
            sourceDigest: sourceDigest,
            rewrittenDigest: rewrittenDigest,
            rewriteModelID: rewriteModelID
        ))
    }

    @discardableResult
    private func saveCredential(
        _ records: CredentialStore,
        owner: CredentialOwner = .vault,
        kind: CredentialKind = .genericToken,
        deviceBound: Bool = false
    ) async throws -> CredentialRecord {
        let record = CredentialRecord(
            kind: kind,
            owner: owner,
            label: "test credential",
            deviceBound: deviceBound
        )
        try await records.save(record)
        return record
    }

    private func githubURL(commit: String, owner: String = "JiangNanGenius",
                           repository: String = "floe-agent",
                           path: String = "skill-hub/skills/alpha/SKILL.md") -> String {
        "https://github.com/\(owner)/\(repository)/blob/\(commit)/\(path)"
    }

    @Test("Official identity ignores the commit pin and reviewed digest")
    func officialIdentityIgnoresPin() async throws {
        let (_, skills, store) = try await makeStore()
        let firstCommit = String(repeating: "a", count: 40)
        let secondCommit = String(repeating: "b", count: 40)
        try await saveSkill(skills, sourceURL: githubURL(commit: firstCommit))

        let first = try await store.snapshot(skillID: "alpha")
        let installation = try #require(first.currentInstallation)
        #expect(installation.trust == .officialHub)
        #expect(installation.publisher == "JiangNanGenius")
        #expect(installation.sourceBinding.hasPrefix("github:jiangnangenius/floe-agent/blob/skill-hub/skills/alpha/"))
        #expect(!installation.sourceBinding.contains(firstCommit))
        #expect(installation.sourcePin == firstCommit)
        #expect(installation.reviewedDigest == "digest-1")

        let saved = try await store.saveVariables(
            skillID: "alpha",
            values: ["endpoint": "https://example.invalid"],
            expectedRevision: nil
        )
        #expect(saved.revision == 1)

        // Same publisher/repository/path, new pin and new reviewed digest.
        try await saveSkill(
            skills,
            sourceURL: githubURL(commit: secondCommit),
            version: "1.1.0",
            rewrittenDigest: "digest-2",
            sourceDigest: "source-2",
            rewriteModelID: "reviewed-2"
        )
        let updated = try await store.snapshot(skillID: "alpha")
        let updatedInstallation = try #require(updated.currentInstallation)
        #expect(updatedInstallation.installationID == installation.installationID)
        #expect(updatedInstallation.sourceBinding == installation.sourceBinding)
        #expect(updatedInstallation.sourcePin == secondCommit)
        #expect(updatedInstallation.reviewedDigest == "digest-2")
        #expect(updated.profile?.revision == 1)
        #expect(updated.entries.first?.value == "https://example.invalid")
        #expect(updated.sourceChanged == false)
    }

    @Test("Different publisher, repo or import path cannot inherit configuration")
    func sourceChangeDoesNotInherit() async throws {
        let (database, skills, store) = try await makeStore()
        let commit = String(repeating: "a", count: 40)
        try await saveSkill(skills, sourceURL: githubURL(commit: commit))
        let original = try await store.saveVariables(
            skillID: "alpha",
            values: ["endpoint": "https://original.invalid"],
            expectedRevision: nil
        )
        let originalInstallation = try #require(
            try await store.snapshot(skillID: "alpha").currentInstallation
        )

        // Same skill ID, different owner: no inherited value or secret scope.
        try await saveSkill(
            skills,
            sourceURL: githubURL(commit: String(repeating: "c", count: 40), owner: "evil"),
            version: "2.0.0",
            rewrittenDigest: "evil-digest"
        )
        let changed = try await store.snapshot(skillID: "alpha")
        #expect(changed.sourceChanged)
        #expect(changed.currentInstallation?.trust == .external)
        #expect(changed.currentInstallation?.installationID != originalInstallation.installationID)
        #expect(changed.profile?.installationID == original.installationID)

        let fresh = try await store.saveVariables(
            skillID: "alpha",
            values: ["endpoint": "https://new.invalid"],
            expectedRevision: nil
        )
        #expect(fresh.installationID == changed.currentInstallation?.installationID)
        #expect(fresh.revision == 1)
        let after = try await store.snapshot(skillID: "alpha")
        #expect(after.entries.count == 1)
        #expect(after.entries.first?.value == "https://new.invalid")
        #expect(!after.sourceChanged)

        let profileCount = try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM skill_config_profiles") ?? 0
        }
        #expect(profileCount == 2)
    }

    @Test("Folder and creator identities preserve URL authority")
    func folderAuthorityIsPreserved() async throws {
        let (_, skills, store) = try await makeStore()
        try await saveSkill(skills, sourceURL: "floe-folder://local/skills/alpha")
        let first = try #require(try await store.snapshot(skillID: "alpha").currentInstallation)
        #expect(first.trust == .external)
        #expect(first.sourceBinding == "folder:/local/skills/alpha")

        try await saveSkill(skills, sourceURL: "floe-folder://local/other/alpha")
        let second = try #require(try await store.snapshot(skillID: "alpha").currentInstallation)
        #expect(second.sourceBinding == "folder:/local/other/alpha")
        #expect(second.installationID != first.installationID)

        try await saveSkill(skills, sourceURL: "floe-creator://evil/alpha")
        let spoofed = try #require(try await store.snapshot(skillID: "alpha").currentInstallation)
        #expect(spoofed.trust == .unknown)
        #expect(!spoofed.configurationAllowed)
        await #expect(throws: SkillConfigurationStoreError.sourceUnverifiable("alpha")) {
            _ = try await store.saveVariables(
                skillID: "alpha",
                values: ["endpoint": "https://example.invalid"]
            )
        }
    }

    @Test("Unbound source fails closed instead of collapsing imports")
    func unboundSourceFailsClosed() async throws {
        let (database, skills, store) = try await makeStore()
        let records = CredentialStore(database: database)
        try await saveSkill(skills, sourceURL: nil)
        let snapshot = try await store.snapshot(skillID: "alpha")
        #expect(snapshot.currentInstallation?.configurationAllowed == false)
        await #expect(throws: SkillConfigurationStoreError.sourceUnverifiable("alpha")) {
            _ = try await store.saveVariables(
                skillID: "alpha",
                values: ["endpoint": "https://example.invalid"]
            )
        }
        let credential = try await saveCredential(records)
        await #expect(throws: SkillConfigurationStoreError.sourceUnverifiable("alpha")) {
            _ = try await store.bind(
                skillID: "alpha",
                fieldKey: "token",
                kind: .secret,
                connectionKind: nil,
                credentialID: credential.id,
                role: .owned
            )
        }
    }

    @Test("Bind checks owner, kind, device binding and revision CAS")
    func bindChecks() async throws {
        let (database, skills, store) = try await makeStore()
        let records = CredentialStore(database: database)
        try await saveSkill(skills, sourceURL: githubURL(commit: String(repeating: "a", count: 40)))
        let vaultCredential = try await saveCredential(records, kind: .genericToken)
        let conversationID = UUID()
        let conversations = SQLiteConversationStore(database: database)
        try await conversations.saveConversation(ConversationRecord(
            id: conversationID,
            title: "Test",
            createdAt: Date(),
            updatedAt: Date()
        ))
        let conversationCredential = try await saveCredential(
            records,
            owner: .conversation(conversationID),
            kind: .genericToken
        )
        _ = try await saveCredential(records, kind: .providerAPIKey)

        let first = try await store.saveVariables(
            skillID: "alpha",
            values: ["endpoint": "https://example.invalid"],
            expectedRevision: nil
        )
        let bound = try await store.bind(
            skillID: "alpha",
            fieldKey: "token",
            kind: .secret,
            connectionKind: nil,
            credentialID: vaultCredential.id,
            role: .owned,
            expectedRevision: first.revision
        )
        #expect(bound.revision == first.revision + 1)

        await #expect(throws: SkillConfigurationStoreError.staleRevision(expected: first.revision, actual: bound.revision)) {
            _ = try await store.saveVariables(
                skillID: "alpha",
                values: ["endpoint": "https://lost.invalid"],
                expectedRevision: first.revision
            )
        }
        await #expect(throws: SkillConfigurationStoreError.credentialNotVaultOwned) {
            _ = try await store.bind(
                skillID: "alpha",
                fieldKey: "other",
                kind: .secret,
                connectionKind: nil,
                credentialID: conversationCredential.id,
                role: .owned
            )
        }
        await #expect(throws: SkillConfigurationStoreError.credentialKindNotAllowed("genericToken")) {
            _ = try await store.bind(
                skillID: "alpha",
                fieldKey: "apiKey",
                kind: .secret,
                connectionKind: nil,
                credentialID: vaultCredential.id,
                role: .owned,
                allowedCredentialKinds: [.providerAPIKey]
            )
        }
        // A plain vault credential is not device-bound.
        await #expect(throws: SkillConfigurationStoreError.connectionMustBeDeviceBound("bridge")) {
            _ = try await store.bind(
                skillID: "alpha",
                fieldKey: "bridge",
                kind: .connection,
                connectionKind: "ios-bridge",
                credentialID: vaultCredential.id,
                role: .owned
            )
        }
        let deviceBound = try await saveCredential(records, kind: .genericToken, deviceBound: true)
        let connection = try await store.bind(
            skillID: "alpha",
            fieldKey: "bridge",
            kind: .connection,
            connectionKind: "ios-bridge",
            credentialID: deviceBound.id,
            role: .owned
        )
        #expect(connection.revision == bound.revision + 1)

        try await store.recordValidation(
            profileID: connection.id,
            fieldKey: "token",
            revision: connection.revision,
            status: .validated,
            validator: "test.v1",
            detail: nil
        )
        let afterValidation = try await store.saveVariables(
            skillID: "alpha",
            values: ["endpoint": "https://changed.invalid"]
        )
        let snapshot = try await store.snapshot(skillID: "alpha")
        #expect(afterValidation.revision == connection.revision + 1)
        #expect(snapshot.validations.isEmpty)
    }

    @Test("Unconfigure releases owned credentials and keeps shared ones")
    func unconfigureReleases() async throws {
        let (database, skills, store) = try await makeStore()
        let records = CredentialStore(database: database)
        try await saveSkill(skills, sourceURL: githubURL(commit: String(repeating: "a", count: 40)))
        _ = try await store.saveVariables(skillID: "alpha", profile: "work", values: ["endpoint": "a"])
        _ = try await store.saveVariables(skillID: "alpha", profile: "home", values: ["endpoint": "b"])
        let owned = try await saveCredential(records)
        let shared = try await saveCredential(records)

        _ = try await store.bind(
            skillID: "alpha", profile: "work", fieldKey: "token",
            kind: .secret, connectionKind: nil,
            credentialID: owned.id, role: .owned
        )
        _ = try await store.bind(
            skillID: "alpha", profile: "home", fieldKey: "token",
            kind: .secret, connectionKind: nil,
            credentialID: shared.id, role: .shared
        )

        let work = try await store.unconfigureProfile(skillID: "alpha", profile: "work")
        #expect(work.ownedUnreferenced == [owned.id])
        #expect(try await store.bindingCount(credentialID: shared.id) == 1)

        let home = try await store.unconfigureProfile(skillID: "alpha", profile: "home")
        #expect(home.ownedUnreferenced.isEmpty)
        #expect(home.sharedRetained == [shared.id])
        #expect(try await store.bindingCount(credentialID: shared.id) == 0)
        #expect(try await records.record(id: shared.id) != nil)
    }

    @Test("Owned credentials cannot be reused by another profile")
    func ownedCredentialCannotBeSharedImplicitly() async throws {
        let (database, skills, store) = try await makeStore()
        let records = CredentialStore(database: database)
        try await saveSkill(skills, sourceURL: githubURL(commit: String(repeating: "a", count: 40)))
        _ = try await store.saveVariables(skillID: "alpha", profile: "one", values: ["endpoint": "a"])
        _ = try await store.saveVariables(skillID: "alpha", profile: "two", values: ["endpoint": "b"])
        let credential = try await saveCredential(records)
        _ = try await store.bind(
            skillID: "alpha", profile: "one", fieldKey: "token",
            kind: .secret, connectionKind: nil,
            credentialID: credential.id, role: .owned
        )
        await #expect(throws: SkillConfigurationStoreError.credentialAlreadyShared(credential.id)) {
            _ = try await store.bind(
                skillID: "alpha", profile: "two", fieldKey: "token",
                kind: .secret, connectionKind: nil,
                credentialID: credential.id, role: .owned
            )
        }
        let shares = try await store.bindingReferences(credentialID: credential.id)
        #expect(shares.count == 1)
    }

    @Test("Local supplemental declarations share revision and source identity")
    func localDeclarations() async throws {
        let (database, skills, store) = try await makeStore()
        let records = CredentialStore(database: database)
        let commit = String(repeating: "a", count: 40)
        try await saveSkill(skills, sourceURL: githubURL(commit: commit))

        let declared = try await store.declareLocalField(
            skillID: "alpha",
            draft: SkillLocalFieldDeclarationDraft(
                fieldKey: "ncbiApiKey",
                kind: .secret,
                required: true,
                environmentName: "NCBI_API_KEY"
            )
        )
        #expect(declared.profile.revision == 1)
        #expect(declared.declaration.environmentName == "NCBI_API_KEY")
        var snapshot = try await store.snapshot(skillID: "alpha")
        #expect(snapshot.localDeclarations.count == 1)
        #expect(snapshot.localDeclarations.first?.kind == .secret)

        let saved = try await store.saveVariables(
            skillID: "alpha",
            values: ["endpoint": "https://example.invalid"]
        )
        #expect(saved.revision == 2)
        let credential = try await saveCredential(records, kind: .genericToken)
        _ = try await store.bind(
            skillID: "alpha",
            fieldKey: "ncbiApiKey",
            kind: .secret,
            connectionKind: nil,
            credentialID: credential.id,
            role: .owned
        )

        // Same publisher and path with a new pin keeps the local declaration.
        try await saveSkill(
            skills,
            sourceURL: githubURL(commit: String(repeating: "b", count: 40)),
            version: "1.1.0",
            rewrittenDigest: "digest-2"
        )
        snapshot = try await store.snapshot(skillID: "alpha")
        #expect(!snapshot.sourceChanged)
        #expect(snapshot.localDeclarations.count == 1)
        #expect(snapshot.binding("ncbiApiKey")?.credentialID == credential.id)

        // Reserved/manifest collisions and connection declarations fail.
        await #expect(throws: SkillConfigurationStoreError.localFieldConflict("'endpoint' is reserved by the installed skill")) {
            _ = try await store.declareLocalField(
                skillID: "alpha",
                draft: SkillLocalFieldDeclarationDraft(
                    fieldKey: "endpoint",
                    kind: .variable,
                    environmentName: "ENDPOINT"
                ),
                reservedFieldKeys: ["endpoint"]
            )
        }
        await #expect(throws: SkillConfigurationStoreError.localFieldConflict("'NCBI_API_KEY' is reserved by the installed skill")) {
            _ = try await store.declareLocalField(
                skillID: "alpha",
                draft: SkillLocalFieldDeclarationDraft(
                    fieldKey: "otherKey",
                    kind: .secret,
                    environmentName: "NCBI_API_KEY"
                ),
                reservedEnvironmentNames: ["NCBI_API_KEY"]
            )
        }
        await #expect(throws: SkillConfigurationStoreError.invalidLocalField("connections cannot be declared locally")) {
            _ = try await store.declareLocalField(
                skillID: "alpha",
                draft: SkillLocalFieldDeclarationDraft(
                    fieldKey: "bridge",
                    kind: .connection,
                    environmentName: "BRIDGE"
                )
            )
        }
        await #expect(throws: SkillConfigurationStoreError.localFieldConflict("environment 'NCBI_API_KEY' is already used by local field 'ncbiApiKey'")) {
            _ = try await store.declareLocalField(
                skillID: "alpha",
                draft: SkillLocalFieldDeclarationDraft(
                    fieldKey: "anotherKey",
                    kind: .secret,
                    environmentName: "NCBI_API_KEY"
                )
            )
        }

        let removed = try await store.removeLocalField(
            skillID: "alpha",
            fieldKey: "ncbiApiKey"
        )
        #expect(removed.released.ownedUnreferenced == [credential.id])
        #expect(try await store.bindingCount(credentialID: credential.id) == 0)
        snapshot = try await store.snapshot(skillID: "alpha")
        #expect(snapshot.localDeclarations.isEmpty)
        #expect(snapshot.binding("ncbiApiKey") == nil)
        #expect(snapshot.entries.first { $0.fieldKey == "ncbiApiKey" } == nil)
    }

    @Test("Local declarations belong to the source identity and profile")
    func localDeclarationSourceIsolation() async throws {
        let (_, skills, store) = try await makeStore()
        try await saveSkill(skills, sourceURL: githubURL(commit: String(repeating: "a", count: 40)))
        _ = try await store.declareLocalField(
            skillID: "alpha",
            draft: SkillLocalFieldDeclarationDraft(
                fieldKey: "mailbox",
                kind: .variable,
                environmentName: "MAILBOX"
            )
        )
        let old = try await store.snapshot(skillID: "alpha")
        #expect(old.localDeclarations.count == 1)

        try await saveSkill(
            skills,
            sourceURL: githubURL(commit: String(repeating: "c", count: 40), owner: "evil"),
            version: "2.0.0",
            rewrittenDigest: "evil"
        )
        let changed = try await store.snapshot(skillID: "alpha")
        #expect(changed.sourceChanged)
        // The old profile still owns the declaration, but the new source has
        // none until it is explicitly re-declared.
        _ = try await store.saveVariables(
            skillID: "alpha",
            values: ["endpoint": "https://new.invalid"]
        )
        let fresh = try await store.snapshot(skillID: "alpha")
        #expect(!fresh.sourceChanged)
        #expect(fresh.localDeclarations.isEmpty)
    }

    @Test("Uninstall retains local declarations with the profile")
    func localDeclarationUninstallRetention() async throws {
        let (_, skills, store) = try await makeStore()
        let url = githubURL(commit: String(repeating: "a", count: 40))
        try await saveSkill(skills, sourceURL: url)
        _ = try await store.declareLocalField(
            skillID: "alpha",
            draft: SkillLocalFieldDeclarationDraft(
                fieldKey: "mailbox",
                kind: .variable,
                environmentName: "MAILBOX"
            )
        )
        try await skills.remove(id: "alpha")
        let removed = try await store.snapshot(skillID: "alpha")
        #expect(removed.localDeclarations.count == 1)
        #expect(!removed.installed)
        try await saveSkill(skills, sourceURL: url)
        let restored = try await store.snapshot(skillID: "alpha")
        #expect(restored.localDeclarations.count == 1)
    }

    @Test("Uninstall retains configuration and reinstall of the same source restores it")
    func uninstallRetainsConfiguration() async throws {
        let (database, skills, store) = try await makeStore()
        let records = CredentialStore(database: database)
        let url = githubURL(commit: String(repeating: "a", count: 40))
        try await saveSkill(skills, sourceURL: url)
        let profile = try await store.saveVariables(
            skillID: "alpha",
            values: ["endpoint": "https://example.invalid"]
        )
        let credential = try await saveCredential(records)
        _ = try await store.bind(
            skillID: "alpha", fieldKey: "token",
            kind: .secret, connectionKind: nil,
            credentialID: credential.id, role: .owned
        )

        try await skills.remove(id: "alpha")
        let removed = try await store.snapshot(skillID: "alpha")
        #expect(!removed.installed)
        #expect(removed.profile?.id == profile.id)
        #expect(removed.binding("token")?.credentialID == credential.id)
        await #expect(throws: SkillConfigurationStoreError.skillNotInstalled("alpha")) {
            _ = try await store.saveVariables(skillID: "alpha", values: ["endpoint": "nope"])
        }

        try await saveSkill(skills, sourceURL: url, version: "1.2.0", rewrittenDigest: "digest-2")
        let reinstalled = try await store.snapshot(skillID: "alpha")
        #expect(reinstalled.installed)
        #expect(reinstalled.profile?.id == profile.id)
        #expect(reinstalled.entries.first?.value == "https://example.invalid")
        #expect(!reinstalled.sourceChanged)
    }
}
