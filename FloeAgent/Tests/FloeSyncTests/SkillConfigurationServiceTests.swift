import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
@testable import FloeSync

private final class FakeSecretStore: VaultSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var lockedAccounts: Set<String> = []
    private var deletedAccounts: [String] = []

    func seed(account: String, secret: Data) {
        lock.lock(); items[account] = secret; lock.unlock()
    }
    func lockAccount(_ account: String) {
        lock.lock(); lockedAccounts.insert(account); lock.unlock()
    }
    func unlockAccount(_ account: String) {
        lock.lock(); lockedAccounts.remove(account); lock.unlock()
    }
    func deleteCount() -> Int {
        lock.lock(); defer { lock.unlock() }; return deletedAccounts.count
    }
    func hasSecret(account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return items[account] != nil
    }
    func secret(account: String) -> Data? {
        lock.lock(); defer { lock.unlock() }; return items[account]
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
        lock.lock()
        items.removeValue(forKey: account)
        deletedAccounts.append(account)
        lock.unlock()
    }
}

private actor TestRuntimeAuthorizer: SkillRuntimeUseAuthorizing {
    private var denyAll = false
    private var requiredRunID: UUID?
    private var requiredTarget: String?
    private var requiredRevision: Int?
    private var requiredGeneration: Int64?
    private(set) var requests: [SkillRuntimeUseRequest] = []

    func setDenyAll(_ value: Bool) {
        denyAll = value
    }

    func configure(
        runID: UUID? = nil,
        target: String? = nil,
        revision: Int? = nil,
        generation: Int64? = nil
    ) {
        requiredRunID = runID
        requiredTarget = target
        requiredRevision = revision
        requiredGeneration = generation
    }

    func authorize(_ request: SkillRuntimeUseRequest) async -> SkillRuntimeUseDecision {
        requests.append(request)
        if denyAll { return .denied("test denial") }
        if let requiredRunID, request.runID != requiredRunID { return .denied("run mismatch") }
        if let requiredTarget, request.target != requiredTarget { return .denied("target mismatch") }
        if let requiredRevision, request.revision != requiredRevision { return .denied("revision mismatch") }
        if let requiredGeneration, request.bindingGeneration != requiredGeneration {
            return .denied("generation mismatch")
        }
        return .allowed
    }
}

private actor ValidationProbe {
    struct Record: Sendable {
        let fieldKey: String
        let connectionKind: String
        let revision: Int
        let variables: [String: String]
        let environment: [String: String]
        let secretEnvironmentNames: [String]
        let secret: Data?
    }

    private(set) var records: [Record] = []

    func record(
        request: SkillConfigurationValidationRequest,
        secret: Data?
    ) {
        records.append(Record(
            fieldKey: request.fieldKey,
            connectionKind: request.connectionKind,
            revision: request.revision,
            variables: request.variables,
            environment: request.environment,
            secretEnvironmentNames: request.secretEnvironment.map(\.name),
            secret: secret
        ))
    }
}

private struct RecordingValidator: SkillConfigurationValidating {
    let supportedConnectionKind: String
    let identifier: String
    let probe: ValidationProbe
    let outcome: SkillConfigurationValidationResult

    init(
        supportedConnectionKind: String = "ios-bridge",
        identifier: String,
        probe: ValidationProbe,
        outcome: SkillConfigurationValidationResult
    ) {
        self.supportedConnectionKind = supportedConnectionKind
        self.identifier = identifier
        self.probe = probe
        self.outcome = outcome
    }

    func validate(
        _ request: SkillConfigurationValidationRequest
    ) async throws -> SkillConfigurationValidationResult {
        let secret = try? await request.readSecret()
        await probe.record(request: request, secret: secret)
        return outcome
    }
}

private struct SkillConfigFixture {
    let database: DatabaseManager
    let skills: SQLiteSkillStore
    let records: CredentialStore
    let local: FakeSecretStore
    let synchronized: FakeSecretStore
    let deviceBound: FakeSecretStore
    let vault: CredentialVaultService
    let authorizer: TestRuntimeAuthorizer
    let store: SkillConfigurationStore
    let service: SkillConfigurationService
    let preferencesSuite: String

    static let officialURL =
        "https://github.com/JiangNanGenius/floe-agent/blob/\(String(repeating: "a", count: 40))/skill-hub/skills/alpha/SKILL.md"

    static func make(
        validators: [any SkillConfigurationValidating] = [],
        officialSources: [SkillOfficialSource] = [
            SkillOfficialSource(
                owner: "JiangNanGenius",
                repository: "floe-agent",
                publisher: "JiangNanGenius"
            )
        ]
    ) async throws -> SkillConfigFixture {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let skills = SQLiteSkillStore(database: database)
        let records = CredentialStore(database: database)
        let local = FakeSecretStore()
        let synchronized = FakeSecretStore()
        let deviceBound = FakeSecretStore()
        let suite = "org.floeagent.tests.skill-config.\(UUID().uuidString)"
        let vault = CredentialVaultService(
            records: records,
            local: local,
            synchronized: synchronized,
            deviceBound: deviceBound,
            preferencesSuite: suite
        )
        let authorizer = TestRuntimeAuthorizer()
        let store = SkillConfigurationStore(
            database: database,
            officialSources: officialSources
        )
        let service = SkillConfigurationService(
            store: store,
            vault: vault,
            validators: validators,
            runtimeUseAuthorizer: authorizer
        )
        return SkillConfigFixture(
            database: database,
            skills: skills,
            records: records,
            local: local,
            synchronized: synchronized,
            deviceBound: deviceBound,
            vault: vault,
            authorizer: authorizer,
            store: store,
            service: service,
            preferencesSuite: suite
        )
    }

    func saveSkill(
        sourceURL: String? = SkillConfigFixture.officialURL,
        version: String = "1.0.0",
        rewrittenDigest: String = "digest-1"
    ) async throws {
        try await skills.save(PersistedSkill(
            id: "alpha",
            name: "alpha",
            version: version,
            skillMarkdown: "body",
            manifestJSON: "{}",
            sourceURL: sourceURL,
            sourceDigest: "source-1",
            rewrittenDigest: rewrittenDigest,
            rewriteModelID: "reviewed-1"
        ))
    }

    func cleanup() {
        UserDefaults(suiteName: preferencesSuite)?
            .removePersistentDomain(forName: preferencesSuite)
    }

    func snapshot(profile: String = "default") async throws -> SkillConfigurationSnapshot {
        try await store.snapshot(skillID: "alpha", profile: profile, target: "default")
    }

    func record(forField fieldKey: String, profile: String = "default") async throws -> CredentialRecord {
        let snapshot = try await snapshot(profile: profile)
        let binding = try #require(snapshot.binding(fieldKey))
        return try #require(await records.record(id: binding.credentialID))
    }
}

private func requirements(
    includeConnection: Bool = true,
    includeEnvironment: Bool = true
) -> SkillConfigRequirements {
    var fields: [SkillConfigFieldRequirement] = [
        SkillConfigFieldRequirement(
            key: "endpoint",
            title: "Endpoint",
            kind: .variable,
            valueType: .url,
            required: true
        ),
        SkillConfigFieldRequirement(
            key: "token",
            title: "Token",
            kind: .secret,
            required: true
        )
    ]
    if includeConnection {
        fields.append(SkillConfigFieldRequirement(
            key: "bridge",
            title: "iOS Bridge",
            kind: .connection,
            required: true,
            connectionKind: "ios-bridge"
        ))
    }
    let environment: [SkillConfigEnvironmentRequirement] = includeEnvironment
        ? [
            SkillConfigEnvironmentRequirement(name: "API_ENDPOINT", fieldKey: "endpoint"),
            SkillConfigEnvironmentRequirement(name: "BRIDGE_TOKEN", fieldKey: "token")
        ]
        : []
    return SkillConfigRequirements(fields: fields, environment: environment)
}

@Suite("Skill configuration service")
struct SkillConfigurationServiceTests {
    @Test("Durable deletion drains the device-bound storage lane too")
    func deleteDeviceBoundCredential() async throws {
        let fixture = try await SkillConfigFixture.make()
        defer { fixture.cleanup() }
        let handle = try await fixture.vault.capture(Data("fixture-pairing".utf8), kind: .genericToken,
            owner: .vault, label: "Fixture pairing", deviceBound: true)
        let record = try #require(try await fixture.records.record(id: handle.id))
        #expect(fixture.deviceBound.hasSecret(account: record.keychainAccount))
        try await fixture.vault.delete(handle)
        #expect(!fixture.deviceBound.hasSecret(account: record.keychainAccount))
        #expect(try await fixture.records.pendingDeletions().isEmpty)
    }

    @Test("Clearing multiple fields is one revision and stale/invalid selections preserve all bindings")
    func clearFieldsAtomically() async throws {
        let fixture = try await SkillConfigFixture.make()
        defer { fixture.cleanup() }
        try await fixture.saveSkill()
        let requirements = requirements()
        let bound = try await fixture.service.bind(
            skillID: "alpha", inputs: [.init(fieldKey: "token", secret: "fixture-token"),
                                       .init(fieldKey: "bridge", secret: "fixture-connection")],
            requirements: requirements, runID: UUID())
        let before = try await fixture.store.snapshot(skillID: "alpha")
        let revision = try #require(before.profile?.revision)
        await #expect(throws: (any Error).self) {
            _ = try await fixture.service.unconfigure(skillID: "alpha", requirements: requirements,
                expectedRevision: revision, expectedProfileID: UUID())
        }
        #expect(try await fixture.store.snapshot(skillID: "alpha").bindings == before.bindings)
        await #expect(throws: (any Error).self) {
            _ = try await fixture.service.unconfigure(skillID: "alpha", fieldKeys: ["token", "unknown"],
                requirements: requirements, expectedRevision: revision)
        }
        #expect(try await fixture.store.snapshot(skillID: "alpha").bindings == before.bindings)
        await #expect(throws: (any Error).self) {
            _ = try await fixture.service.unconfigure(skillID: "alpha", fieldKeys: ["token", "bridge"],
                requirements: requirements, expectedRevision: revision + 1)
        }
        #expect(try await fixture.store.snapshot(skillID: "alpha").bindings == before.bindings)
        let cleared = try await fixture.service.unconfigure(skillID: "alpha", fieldKeys: ["token", "bridge"],
            requirements: requirements, expectedRevision: revision)
        #expect(cleared.warnings.isEmpty)
        #expect(cleared.status.revision == bound.status.revision.map { $0 + 1 })
        #expect(try await fixture.store.snapshot(skillID: "alpha").bindings.isEmpty)
    }

    @Test("Save and raw bind produce secret-free status with separate env plans")
    func saveAndBind() async throws {
        let fixture = try await SkillConfigFixture.make()
        defer { fixture.cleanup() }
        try await fixture.saveSkill()
        let requirements = requirements()

        let initial = try await fixture.service.inspect(
            skillID: "alpha",
            requirements: requirements
        )
        #expect(initial.readiness == .needsSetup)
        #expect(Set(initial.missingRequiredFields) == ["endpoint", "token", "bridge"])

        var outcome = try await fixture.service.saveValues(
            skillID: "alpha",
            values: ["endpoint": "https://example.invalid/api"],
            requirements: requirements
        )
        #expect(outcome.status.readiness == .needsSetup)
        #expect(outcome.status.fields.first { $0.key == "endpoint" }?.value == "https://example.invalid/api")

        let token = "raw-token-\(UUID().uuidString)"
        let bridgeSecret = "opaque-pairing-\(UUID().uuidString)"
        outcome = try await fixture.service.bind(
            skillID: "alpha",
            inputs: [
                .init(fieldKey: "token", secret: token),
                .init(fieldKey: "bridge", secret: bridgeSecret)
            ],
            requirements: requirements,
            runID: UUID()
        )
        #expect(outcome.status.readiness == .needsValidation)

        let tokenField = try #require(outcome.status.fields.first { $0.key == "token" })
        #expect(tokenField.value == nil)
        #expect(tokenField.credentialReference?.hasPrefix("⟨credential:") == true)
        #expect(tokenField.state == .configured)
        let bridgeField = try #require(outcome.status.fields.first { $0.key == "bridge" })
        #expect(bridgeField.state == .validationRequired)
        #expect(bridgeField.secretEnvironmentNames.isEmpty)

        #expect(outcome.status.environmentNames == ["API_ENDPOINT"])
        let secretRequest = try #require(outcome.status.secretEnvironment.first)
        #expect(secretRequest.name == "BRIDGE_TOKEN")
        #expect(secretRequest.fieldKey == "token")
        #expect(secretRequest.delivery == .nativeCredentialReference)
        #expect(!secretRequest.credentialReference.contains(token))

        let tokenRecord = try await fixture.record(forField: "token")
        #expect(!tokenRecord.deviceBound)
        #expect(try await fixture.vault.resolveForApprovedUse(CredentialHandle(id: tokenRecord.id)) == Data(token.utf8))
        let bridgeRecord = try await fixture.record(forField: "bridge")
        #expect(bridgeRecord.deviceBound)
        #expect(!bridgeRecord.synchronizable)
        #expect(fixture.deviceBound.hasSecret(account: bridgeRecord.keychainAccount))
        #expect(!fixture.local.hasSecret(account: bridgeRecord.keychainAccount))
    }

    @Test("Validation is only successful through a real injected validator")
    func validationLifecycle() async throws {
        let probe = ValidationProbe()
        let fixture = try await SkillConfigFixture.make()
        defer { fixture.cleanup() }
        try await fixture.saveSkill()
        let requirements = requirements()
        _ = try await fixture.service.saveValues(
            skillID: "alpha",
            values: ["endpoint": "https://example.invalid/api"],
            requirements: requirements
        )
        let token = "token-\(UUID().uuidString)"
        let bridgeSecret = "pairing-\(UUID().uuidString)"
        _ = try await fixture.service.bind(
            skillID: "alpha",
            inputs: [
                .init(fieldKey: "token", secret: token),
                .init(fieldKey: "bridge", secret: bridgeSecret)
            ],
            requirements: requirements,
            runID: UUID()
        )

        // No validator: unsupported, never a fake success.
        var outcome = try await fixture.service.validate(
            skillID: "alpha",
            requirements: requirements
        )
        #expect(outcome.status.readiness == .needsValidation)
        #expect(outcome.status.validation.first?.status == .unsupported)
        #expect(outcome.status.validation.first?.validator == "unavailable:ios-bridge")

        let validating = fixture.service.withValidator(RecordingValidator(
            identifier: "ios-bridge.test.v1",
            probe: probe,
            outcome: .valid(message: "paired")
        ))
        outcome = try await validating.validate(
            skillID: "alpha",
            requirements: requirements
        )
        #expect(outcome.status.readiness == .ready)
        let validation = try #require(outcome.status.validation.first)
        #expect(validation.status == .validated)
        #expect(validation.validator == "ios-bridge.test.v1")
        #expect(validation.revision == outcome.status.revision)

        let records = await probe.records
        let request = try #require(records.first)
        #expect(request.fieldKey == "bridge")
        #expect(request.connectionKind == "ios-bridge")
        #expect(request.variables["endpoint"] == "https://example.invalid/api")
        #expect(request.environment == ["API_ENDPOINT": "https://example.invalid/api"])
        #expect(request.secretEnvironmentNames == ["BRIDGE_TOKEN"])
        // The validator reads its own connection secret, never another
        // field's secret.
        #expect(request.secret == Data(bridgeSecret.utf8))

        // Editing the configuration invalidates the old validation receipt.
        outcome = try await validating.saveValues(
            skillID: "alpha",
            values: ["endpoint": "https://changed.invalid/api"],
            requirements: requirements
        )
        #expect(outcome.status.readiness == .needsValidation)
        #expect(outcome.status.validation.isEmpty)
    }

    @Test("Runtime resolve and secret reads are fenced by the native authorizer")
    func runtimeAuthorizationFences() async throws {
        let probe = ValidationProbe()
        let fixture = try await SkillConfigFixture.make(validators: [
            RecordingValidator(
                identifier: "ios-bridge.test.v1",
                probe: probe,
                outcome: .valid(message: nil)
            )
        ])
        defer { fixture.cleanup() }
        try await fixture.saveSkill()
        let requirements = requirements()
        _ = try await fixture.service.saveValues(
            skillID: "alpha",
            values: ["endpoint": "https://example.invalid/api"],
            requirements: requirements
        )
        let token = "runtime-token-\(UUID().uuidString)"
        _ = try await fixture.service.bind(
            skillID: "alpha",
            inputs: [
                .init(fieldKey: "token", secret: token),
                .init(fieldKey: "bridge", secret: "pairing-\(UUID().uuidString)")
            ],
            requirements: requirements,
            runID: UUID()
        )
        _ = try await fixture.service.validate(skillID: "alpha", requirements: requirements)
        let runID = UUID()
        let active: Set<String> = ["alpha"]
        let request = SkillConfigurationResolutionRequest(
            skillID: "alpha",
            bindingGeneration: 7
        )

        // Active skill IDs are provenance only: denial still wins.
        await fixture.authorizer.setDenyAll(true)
        await #expect(throws: SkillConfigurationError.runtimeUseDenied("test denial")) {
            _ = try await fixture.service.resolve(
                request: request,
                provenance: SkillRuntimeProvenance(runID: runID, activeSkillIDs: active),
                requirements: requirements
            )
        }

        await fixture.authorizer.setDenyAll(false)
        let payload = try await fixture.service.resolve(
            request: request,
            provenance: SkillRuntimeProvenance(runID: runID, activeSkillIDs: active),
            requirements: requirements
        )
        #expect(payload.environment == ["API_ENDPOINT": "https://example.invalid/api"])
        #expect(payload.secretEnvironment.map(\.name) == ["BRIDGE_TOKEN"])
        #expect(payload.secretBindings["token"]?.deviceBound == false)
        #expect(payload.secretBindings["bridge"]?.deviceBound == true)
        #expect(try await fixture.service.readSecret("token", in: payload) == Data(token.utf8))

        let requests = await fixture.authorizer.requests
        #expect(requests.contains { $0.operation == .resolve && $0.bindingGeneration == 7 })
        #expect(requests.contains { $0.operation == .readSecret && $0.fieldKey == "token" })

        // Revocation after resolve fences the already-issued payload.
        await fixture.authorizer.setDenyAll(true)
        await #expect(throws: SkillConfigurationError.runtimeUseDenied("test denial")) {
            _ = try await fixture.service.readSecret("token", in: payload)
        }

        // Wrong target or generation, even with active IDs and an allowing
        // authorizer, is denied before mint.
        await fixture.authorizer.setDenyAll(false)
        await fixture.authorizer.configure(runID: runID, target: "other-target")
        await #expect(throws: (any Error).self) {
            _ = try await fixture.service.resolve(
                request: request,
                provenance: SkillRuntimeProvenance(runID: runID, activeSkillIDs: active),
                requirements: requirements
            )
        }
        await fixture.authorizer.configure(runID: runID, target: "default", generation: 8)
        await #expect(throws: (any Error).self) {
            _ = try await fixture.service.resolve(
                request: request,
                provenance: SkillRuntimeProvenance(runID: runID, activeSkillIDs: active),
                requirements: requirements
            )
        }

        // A run whose provenance does not include the skill cannot resolve at
        // all (the authorizer is not even consulted as a substitute).
        await fixture.authorizer.configure()
        await #expect(throws: SkillConfigurationError.runtimeProvenanceRejectsSkill("alpha")) {
            _ = try await fixture.service.resolve(
                request: request,
                provenance: SkillRuntimeProvenance(runID: runID, activeSkillIDs: []),
                requirements: requirements
            )
        }
    }

    @Test("Normalizer capture is consumed only by the same run and field")
    func captureReferenceAuthorization() async throws {
        let fixture = try await SkillConfigFixture.make()
        defer { fixture.cleanup() }
        try await fixture.saveSkill()
        let requirements = requirements(includeConnection: false)
        _ = try await fixture.service.saveValues(
            skillID: "alpha",
            values: ["endpoint": "https://example.invalid/api"],
            requirements: requirements
        )
        let runID = UUID()
        let raw = "captured-\(UUID().uuidString)"
        let input = try JSONSerialization.data(withJSONObject: [
            "bindings": [["field": "token", "secret": raw]]
        ])
        let normalized = try await CredentialArgumentNormalizer.normalize(
            input,
            toolName: SkillConfigurationService.toolName,
            vault: fixture.vault,
            authority: RunCredentialAuthority(
                runID: runID,
                toolName: SkillConfigurationService.toolName,
                targetScope: .local
            )
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: normalized) as? [String: Any]
        )
        let bindings = try #require(object["bindings"] as? [[String: Any]])
        let placeholder = try #require(bindings.first?["secret"] as? String)
        let captureID = try #require(SecretIngressScanner.credentialID(from: placeholder))
        #expect(try await fixture.records.record(id: captureID) != nil)

        // Wrong run: refused, capture and configuration unchanged.
        await #expect(throws: SkillConfigurationError.invalidCaptureReference) {
            _ = try await fixture.service.bind(
                skillID: "alpha",
                inputs: [.init(
                    fieldKey: "token",
                    secret: placeholder,
                    captureFieldPath: "bindings.0.secret"
                )],
                requirements: requirements,
                runID: UUID()
            )
        }
        #expect(try await fixture.records.record(id: captureID) != nil)

        let outcome = try await fixture.service.bind(
            skillID: "alpha",
            inputs: [.init(
                fieldKey: "token",
                secret: placeholder,
                captureFieldPath: "bindings.0.secret"
            )],
            requirements: requirements,
            runID: runID
        )
        #expect(outcome.status.fields.first { $0.key == "token" }?.state == .configured)
        #expect(try await fixture.records.record(id: captureID) == nil)
        let record = try await fixture.record(forField: "token")
        #expect(try await fixture.vault.resolveForApprovedUse(CredentialHandle(id: record.id)) == Data(raw.utf8))
        #expect(outcome.status.fields.first { $0.key == "token" }?.value == nil)
    }

    @Test("Shared credentials need explicit reuse and survive unbinding")
    func sharingAndRelease() async throws {
        let fixture = try await SkillConfigFixture.make()
        defer { fixture.cleanup() }
        try await fixture.saveSkill()
        let requirements = requirements(includeConnection: false)
        _ = try await fixture.service.saveValues(
            skillID: "alpha", profile: "one",
            values: ["endpoint": "https://one.invalid/a"],
            requirements: requirements
        )
        _ = try await fixture.service.saveValues(
            skillID: "alpha", profile: "two",
            values: ["endpoint": "https://two.invalid/a"],
            requirements: requirements
        )
        let shared = try await fixture.vault.capture(
            Data("shared-\(UUID().uuidString)".utf8),
            kind: .genericToken,
            owner: .vault,
            label: "Shared token",
            origin: "test"
        )
        _ = try await fixture.service.bind(
            skillID: "alpha", profile: "one",
            inputs: [.init(fieldKey: "token", credentialID: shared.id)],
            requirements: requirements,
            runID: UUID()
        )
        await #expect(throws: SkillConfigurationError.requiresExplicitSharing) {
            _ = try await fixture.service.bind(
                skillID: "alpha", profile: "two",
                inputs: [.init(fieldKey: "token", credentialID: shared.id)],
                requirements: requirements,
                runID: UUID()
            )
        }
        _ = try await fixture.service.bind(
            skillID: "alpha", profile: "two",
            inputs: [.init(fieldKey: "token", credentialID: shared.id, shareExisting: true)],
            requirements: requirements,
            runID: UUID()
        )
        let unbound = try await fixture.service.unconfigure(
            skillID: "alpha", profile: "one",
            fieldKeys: ["token"],
            requirements: requirements
        )
        #expect(unbound.status.readiness == .needsSetup)
        #expect(try await fixture.records.record(id: shared.id) != nil)
        #expect(try await fixture.store.bindingCount(credentialID: shared.id) == 1)

        // An owned secret is released when its profile is removed.
        let owned = try await fixture.service.bind(
            skillID: "alpha", profile: "owned",
            inputs: [.init(fieldKey: "token", secret: "owned-\(UUID().uuidString)")],
            requirements: SkillConfigRequirements(fields: requirements.fields),
            runID: UUID()
        )
        // The "owned" profile has no endpoint yet; bind still created it.
        #expect(owned.status.fields.first { $0.key == "token" }?.bindingRole == .owned)
        let ownedRecord = try await fixture.record(forField: "token", profile: "owned")
        let removed = try await fixture.service.unconfigure(
            skillID: "alpha", profile: "owned",
            requirements: requirements
        )
        #expect(removed.warnings.isEmpty)
        #expect(try await fixture.records.record(id: ownedRecord.id) == nil)
    }

    @Test("Locked credential is reported and never deleted")
    func lockedCredential() async throws {
        let fixture = try await SkillConfigFixture.make()
        defer { fixture.cleanup() }
        try await fixture.saveSkill()
        let requirements = requirements(includeConnection: false)
        _ = try await fixture.service.saveValues(
            skillID: "alpha",
            values: ["endpoint": "https://example.invalid/api"],
            requirements: requirements
        )
        _ = try await fixture.service.bind(
            skillID: "alpha",
            inputs: [.init(fieldKey: "token", secret: "locked-\(UUID().uuidString)")],
            requirements: requirements,
            runID: UUID()
        )
        let record = try await fixture.record(forField: "token")
        let deletesBefore = fixture.local.deleteCount()
        fixture.local.lockAccount(record.keychainAccount)

        let locked = try await fixture.service.inspect(
            skillID: "alpha",
            requirements: requirements
        )
        #expect(locked.readiness == .locked)
        #expect(locked.fields.first { $0.key == "token" }?.state == .locked)
        #expect(try await fixture.records.record(id: record.id) != nil)
        #expect(fixture.local.deleteCount() == deletesBefore)

        await #expect(throws: (any Error).self) {
            _ = try await fixture.service.resolve(
                request: .init(skillID: "alpha"),
                provenance: SkillRuntimeProvenance(runID: UUID(), activeSkillIDs: ["alpha"]),
                requirements: requirements
            )
        }

        fixture.local.unlockAccount(record.keychainAccount)
        let unlocked = try await fixture.service.inspect(
            skillID: "alpha",
            requirements: requirements
        )
        #expect(unlocked.fields.first { $0.key == "token" }?.state == .configured)
    }

    @Test("A changed source cannot inherit saved configuration or secrets")
    func sourceChangeRevokesSecrets() async throws {
        let fixture = try await SkillConfigFixture.make()
        defer { fixture.cleanup() }
        try await fixture.saveSkill()
        let requirements = requirements(includeConnection: false)
        _ = try await fixture.service.saveValues(
            skillID: "alpha",
            values: ["endpoint": "https://old.invalid/api"],
            requirements: requirements
        )
        _ = try await fixture.service.bind(
            skillID: "alpha",
            inputs: [.init(fieldKey: "token", secret: "old-\(UUID().uuidString)")],
            requirements: requirements,
            runID: UUID()
        )
        let oldRecord = try await fixture.record(forField: "token")

        try await fixture.saveSkill(
            sourceURL: "https://github.com/evil/floe-agent/blob/\(String(repeating: "b", count: 40))/skill-hub/skills/alpha/SKILL.md",
            version: "2.0.0",
            rewrittenDigest: "evil-digest"
        )
        let changed = try await fixture.service.inspect(
            skillID: "alpha",
            requirements: requirements
        )
        #expect(changed.sourceChanged)
        #expect(changed.readiness == .needsReconfirmation)
        await #expect(throws: (any Error).self) {
            _ = try await fixture.service.resolve(
                request: .init(skillID: "alpha"),
                provenance: SkillRuntimeProvenance(runID: UUID(), activeSkillIDs: ["alpha"]),
                requirements: requirements
            )
        }

        // A fresh configuration under the new source starts empty; the old
        // credential record remains but is not reachable through it.
        let fresh = try await fixture.service.inspect(
            skillID: "alpha",
            requirements: requirements
        )
        #expect(fresh.revision == changed.revision)
        _ = try await fixture.service.saveValues(
            skillID: "alpha",
            values: ["endpoint": "https://new.invalid/api"],
            requirements: requirements
        )
        let after = try await fixture.service.inspect(
            skillID: "alpha",
            requirements: requirements
        )
        #expect(!after.sourceChanged)
        #expect(after.revision == 1)
        #expect(after.fields.first { $0.key == "endpoint" }?.value == "https://new.invalid/api")
        #expect(after.fields.first { $0.key == "token" }?.state == .missing)
        #expect(try await fixture.records.record(id: oldRecord.id) != nil)
    }

    @Test("Validator dispatch uses connection kind, not its provenance identifier")
    func validatorDispatchSeparatesKindAndIdentifier() async throws {
        let probe = ValidationProbe()
        let fixture = try await SkillConfigFixture.make(validators: [
            RecordingValidator(
                supportedConnectionKind: "ios-bridge",
                identifier: "ios-bridge.rpc.v1",
                probe: probe,
                outcome: .valid(message: nil)
            )
        ])
        defer { fixture.cleanup() }
        try await fixture.saveSkill()
        let requirements = SkillConfigRequirements(fields: [
            SkillConfigFieldRequirement(
                key: "bridge",
                kind: .connection,
                required: true,
                connectionKind: "ios-bridge"
            ),
            SkillConfigFieldRequirement(
                key: "legacy",
                kind: .connection,
                required: true,
                connectionKind: "unknown-link"
            )
        ])
        _ = try await fixture.service.bind(
            skillID: "alpha",
            inputs: [
                .init(fieldKey: "bridge", secret: "pair-1"),
                .init(fieldKey: "legacy", secret: "pair-2")
            ],
            requirements: requirements,
            runID: UUID()
        )
        let outcome = try await fixture.service.validate(
            skillID: "alpha",
            requirements: requirements
        )
        #expect(outcome.status.readiness == .needsValidation)
        let bridge = try #require(outcome.status.validation.first { $0.fieldKey == "bridge" })
        #expect(bridge.status == .validated)
        #expect(bridge.validator == "ios-bridge.rpc.v1")
        let legacy = try #require(outcome.status.validation.first { $0.fieldKey == "legacy" })
        #expect(legacy.status == .unsupported)
        #expect(legacy.validator == "unavailable:unknown-link")
    }

    @Test("User-local ENV declarations merge without granting permissions")
    func localFieldLifecycle() async throws {
        let fixture = try await SkillConfigFixture.make()
        defer { fixture.cleanup() }
        try await fixture.saveSkill()
        let manifest = SkillConfigRequirements()

        // A third-party skill with no configuration block can declare a local
        // ordinary ENV field.
        var outcome = try await fixture.service.declareField(
            skillID: "alpha",
            draft: SkillLocalFieldDeclarationDraft(
                fieldKey: "mailbox",
                kind: .variable,
                title: "Contact email",
                required: true,
                environmentName: "NCBI_EMAIL"
            ),
            requirements: manifest
        )
        #expect(outcome.status.readiness == .needsSetup)
        let localField = try #require(outcome.status.fields.first)
        #expect(localField.declaredBy == .local)
        #expect(localField.environmentNames == ["NCBI_EMAIL"])
        #expect(outcome.status.revision == 1)
        #expect(try await fixture.service.localDeclarations(skillID: "alpha").count == 1)

        outcome = try await fixture.service.saveValues(
            skillID: "alpha",
            values: ["mailbox": "person@example.invalid"],
            requirements: manifest
        )
        #expect(outcome.status.readiness == .configured)
        #expect(outcome.status.environmentNames == ["NCBI_EMAIL"])

        // A local secret field is explicitly declared but carries no value and
        // never inherits an unrelated stored secret.
        _ = try await fixture.vault.capture(
            Data("unrelated-\(UUID().uuidString)".utf8),
            kind: .genericToken,
            owner: .vault,
            label: "Unrelated"
        )
        outcome = try await fixture.service.declareField(
            skillID: "alpha",
            draft: SkillLocalFieldDeclarationDraft(
                fieldKey: "apiKey",
                kind: .secret,
                required: true,
                environmentName: "NCBI_API_KEY"
            ),
            requirements: manifest,
            expectedRevision: outcome.status.revision
        )
        #expect(outcome.status.readiness == .needsSetup)
        #expect(outcome.status.fields.first { $0.key == "apiKey" }?.state == .missing)
        #expect(outcome.status.fields.first { $0.key == "apiKey" }?.credentialReference == nil)
        #expect(outcome.status.secretEnvironment.isEmpty)

        let apiKey = "local-secret-\(UUID().uuidString)"
        outcome = try await fixture.service.bind(
            skillID: "alpha",
            inputs: [.init(fieldKey: "apiKey", secret: apiKey)],
            requirements: manifest,
            runID: UUID()
        )
        #expect(outcome.status.readiness == .configured)
        let secretRequest = try #require(outcome.status.secretEnvironment.first)
        #expect(secretRequest.name == "NCBI_API_KEY")
        #expect(secretRequest.fieldKey == "apiKey")

        let runID = UUID()
        let payload = try await fixture.service.resolve(
            request: .init(skillID: "alpha"),
            provenance: SkillRuntimeProvenance(runID: runID, activeSkillIDs: ["alpha"]),
            requirements: manifest
        )
        #expect(payload.environment == ["NCBI_EMAIL": "person@example.invalid"])
        #expect(payload.secretEnvironment.map(\.name) == ["NCBI_API_KEY"])
        #expect(try await fixture.service.readSecret("apiKey", in: payload) == Data(apiKey.utf8))
        let apiKeyRecord = try await fixture.record(forField: "apiKey")
        #expect(try await fixture.records.record(id: apiKeyRecord.id) != nil)

        // Declaring another field invalidates any previous revision receipt.
        let stale = try #require(outcome.status.revision)
        await #expect(throws: SkillConfigurationStoreError.staleRevision(expected: stale - 1, actual: stale)) {
            _ = try await fixture.service.declareField(
                skillID: "alpha",
                draft: SkillLocalFieldDeclarationDraft(
                    fieldKey: "secondVariable",
                    kind: .variable,
                    environmentName: "SECOND"
                ),
                requirements: manifest,
                expectedRevision: stale - 1
            )
        }

        let removed = try await fixture.service.removeField(
            skillID: "alpha",
            fieldKey: "apiKey",
            requirements: manifest
        )
        #expect(removed.status.secretEnvironment.isEmpty)
        #expect(try await fixture.records.record(id: apiKeyRecord.id) == nil)
        #expect(try await fixture.service.localDeclarations(skillID: "alpha").count == 1)
        await #expect(throws: SkillConfigurationError.self) {
            let rebuilt = try await fixture.service.resolve(
                request: .init(skillID: "alpha"),
                provenance: SkillRuntimeProvenance(runID: runID, activeSkillIDs: ["alpha"]),
                requirements: manifest
            )
            _ = try await fixture.service.readSecret("apiKey", in: rebuilt)
        }
    }

    @Test("Local declarations cannot override manifest, native or connection fields")
    func localFieldBoundaries() async throws {
        let fixture = try await SkillConfigFixture.make()
        defer { fixture.cleanup() }
        try await fixture.saveSkill()
        let manifest = SkillConfigRequirements(fields: [
            SkillConfigFieldRequirement(
                key: "endpoint",
                kind: .variable,
                valueType: .url,
                required: true
            )
        ], environment: [
            SkillConfigEnvironmentRequirement(name: "ENDPOINT", fieldKey: "endpoint")
        ])

        await #expect(throws: SkillConfigurationStoreError.localFieldConflict("'endpoint' is reserved by the installed skill")) {
            _ = try await fixture.service.declareField(
                skillID: "alpha",
                draft: SkillLocalFieldDeclarationDraft(
                    fieldKey: "endpoint",
                    kind: .variable,
                    environmentName: "OTHER_ENDPOINT"
                ),
                requirements: manifest
            )
        }
        await #expect(throws: SkillConfigurationStoreError.localFieldConflict("'ENDPOINT' is reserved by the installed skill")) {
            _ = try await fixture.service.declareField(
                skillID: "alpha",
                draft: SkillLocalFieldDeclarationDraft(
                    fieldKey: "other",
                    kind: .variable,
                    environmentName: "ENDPOINT"
                ),
                requirements: manifest
            )
        }
        await #expect(throws: SkillConfigurationStoreError.localFieldConflict("'PATH' is reserved by the installed skill")) {
            _ = try await fixture.service.declareField(
                skillID: "alpha",
                draft: SkillLocalFieldDeclarationDraft(
                    fieldKey: "pathOverride",
                    kind: .variable,
                    environmentName: "PATH"
                ),
                requirements: manifest
            )
        }
        await #expect(throws: SkillConfigurationStoreError.invalidLocalField("connections cannot be declared locally")) {
            _ = try await fixture.service.declareField(
                skillID: "alpha",
                draft: SkillLocalFieldDeclarationDraft(
                    fieldKey: "bridge",
                    kind: .connection,
                    environmentName: "BRIDGE"
                ),
                requirements: manifest
            )
        }

        // A later same-source update that declares a colliding local field is
        // excluded fail-closed and reported, not silently merged.
        _ = try await fixture.service.declareField(
            skillID: "alpha",
            draft: SkillLocalFieldDeclarationDraft(
                fieldKey: "mailbox",
                kind: .variable,
                required: true,
                environmentName: "MAILBOX"
            ),
            requirements: manifest
        )
        let updatedManifest = SkillConfigRequirements(
            fields: manifest.fields + [
                SkillConfigFieldRequirement(
                    key: "mailbox",
                    kind: .variable,
                    valueType: .string,
                    required: true
                )
            ],
            environment: manifest.environment + [
                SkillConfigEnvironmentRequirement(name: "MAILBOX", fieldKey: "mailbox")
            ]
        )
        let status = try await fixture.service.inspect(
            skillID: "alpha",
            requirements: updatedManifest
        )
        #expect(status.localDeclarationConflicts.count == 1)
        #expect(status.localDeclarationConflicts.first?.fieldKey == "mailbox")
        let mailboxFields = status.fields.filter { $0.key.caseInsensitiveCompare("mailbox") == .orderedSame }
        #expect(mailboxFields.count == 1)
        #expect(mailboxFields.first?.declaredBy == .manifest)
    }

    private func bridgeRequirements(
        connectionKind: String = "ios.bridge.local"
    ) -> SkillConfigRequirements {
        SkillConfigRequirements(fields: [
            SkillConfigFieldRequirement(
                key: "bridge",
                kind: .connection,
                required: true,
                connectionKind: connectionKind
            )
        ])
    }

    @Test("Native connection payload setup and metadata refresh are fenced")
    func nativeConnectionPayloadLifecycle() async throws {
        let probe = ValidationProbe()
        let fixture = try await SkillConfigFixture.make(validators: [
            RecordingValidator(
                supportedConnectionKind: "ios.bridge.local",
                identifier: "ios.bridge.local.rpc.v1",
                probe: probe,
                outcome: .valid(message: "paired")
            )
        ])
        defer { fixture.cleanup() }
        try await fixture.saveSkill()
        let requirements = bridgeRequirements()
        let target = "local-ios"
        let firstPayload = Data("pairing-record-1".utf8)

        // Before setup there is nothing to read.
        await #expect(throws: SkillConfigurationError.credentialMissing("bridge")) {
            _ = try await fixture.service.readConnectionPayload(
                skillID: "alpha",
                target: target,
                fieldKey: "bridge",
                connectionKind: "ios.bridge.local",
                requirements: requirements
            )
        }

        let setup = try await fixture.service.saveConnectionPayload(
            skillID: "alpha",
            target: target,
            fieldKey: "bridge",
            connectionKind: "ios.bridge.local",
            payload: firstPayload,
            reason: .initialSetup,
            requirements: requirements
        )
        #expect(setup.created)
        #expect(setup.revision == 1)
        #expect(setup.replacedCredentialID == nil)
        let payload = try await fixture.service.readConnectionPayload(
            skillID: "alpha",
            target: target,
            fieldKey: "bridge",
            connectionKind: "ios.bridge.local",
            requirements: requirements
        )
        #expect(payload.payload == firstPayload)
        #expect(payload.deviceBound)
        #expect(payload.revision == setup.revision)
        let record = try #require(try await fixture.records.record(id: setup.credentialID))
        #expect(record.owner == .vault)
        #expect(record.deviceBound)
        #expect(!record.synchronizable)
        #expect(record.origin?.hasPrefix("skill-connection:") == true)
        #expect(fixture.deviceBound.hasSecret(account: record.keychainAccount))

        var status = try await fixture.service.validate(
            skillID: "alpha",
            target: target,
            requirements: requirements
        )
        #expect(status.status.readiness == .ready)
        #expect(status.status.validation.first?.validator == "ios.bridge.local.rpc.v1")
        let validationRevision = status.status.revision

        // Same client/token/key metadata refresh: payload changes, revision
        // and successful validation do not.
        let refreshedPayload = Data("pairing-record-1+timestamp".utf8)
        let refreshed = try await fixture.service.refreshConnectionPayload(
            skillID: "alpha",
            target: target,
            fieldKey: "bridge",
            connectionKind: "ios.bridge.local",
            payload: refreshedPayload,
            requirements: requirements,
            expectedCredentialID: setup.credentialID,
            expectedRevision: try #require(validationRevision)
        )
        #expect(refreshed.revision == validationRevision)
        #expect(try await fixture.service.readConnectionPayload(
            skillID: "alpha",
            target: target,
            fieldKey: "bridge",
            connectionKind: "ios.bridge.local",
            requirements: requirements
        ).payload == refreshedPayload)
        status = try await fixture.service.validate(
            skillID: "alpha",
            target: target,
            requirements: requirements
        )
        #expect(status.status.readiness == .ready)
        #expect(status.status.revision == validationRevision)

        let validatedRevision = try #require(validationRevision)
        // A late refresh with the old credential id/revision is refused.
        await #expect(throws: SkillConfigurationError.connectionBindingChanged) {
            _ = try await fixture.service.refreshConnectionPayload(
                skillID: "alpha",
                target: target,
                fieldKey: "bridge",
                connectionKind: "ios.bridge.local",
                payload: Data("late-old".utf8),
                requirements: requirements,
                expectedCredentialID: setup.credentialID,
                expectedRevision: validatedRevision - 1
            )
        }

        // New key: a new credential/binding and revision; the old one is
        // released and the previous validation is invalid.
        let secondPayload = Data("pairing-record-2".utf8)
        let rekey = try await fixture.service.saveConnectionPayload(
            skillID: "alpha",
            target: target,
            fieldKey: "bridge",
            connectionKind: "ios.bridge.local",
            payload: secondPayload,
            reason: .rekey,
            requirements: requirements,
            expectedCredentialID: setup.credentialID,
            expectedRevision: validatedRevision
        )
        #expect(!rekey.created)
        #expect(rekey.credentialID != setup.credentialID)
        #expect(rekey.replacedCredentialID == setup.credentialID)
        #expect(rekey.revision != validationRevision)
        #expect(rekey.warnings.isEmpty)
        #expect(try await fixture.records.record(id: setup.credentialID) == nil)
        #expect(try await fixture.service.readConnectionPayload(
            skillID: "alpha",
            target: target,
            fieldKey: "bridge",
            connectionKind: "ios.bridge.local",
            requirements: requirements
        ).payload == secondPayload)
        let inspected = try await fixture.service.inspect(
            skillID: "alpha",
            target: target,
            requirements: requirements
        )
        #expect(inspected.readiness == .needsValidation)
        #expect(inspected.validation.isEmpty)

        // Old refresh after re-key cannot overwrite the new binding.
        await #expect(throws: SkillConfigurationError.connectionBindingChanged) {
            _ = try await fixture.service.refreshConnectionPayload(
                skillID: "alpha",
                target: target,
                fieldKey: "bridge",
                connectionKind: "ios.bridge.local",
                payload: Data("stale-overwrite".utf8),
                requirements: requirements,
                expectedCredentialID: setup.credentialID,
                expectedRevision: validatedRevision
            )
        }
        #expect(try await fixture.service.readConnectionPayload(
            skillID: "alpha",
            target: target,
            fieldKey: "bridge",
            connectionKind: "ios.bridge.local",
            requirements: requirements
        ).payload == secondPayload)

        // Locked Keychain is reported without deleting the binding.
        let current = try #require(try await fixture.records.record(id: rekey.credentialID))
        fixture.deviceBound.lockAccount(current.keychainAccount)
        let deletesBefore = fixture.deviceBound.deleteCount()
        await #expect(throws: SkillConfigurationError.credentialLocked("bridge")) {
            _ = try await fixture.service.readConnectionPayload(
                skillID: "alpha",
                target: target,
                fieldKey: "bridge",
                connectionKind: "ios.bridge.local",
                requirements: requirements
            )
        }
        #expect(try await fixture.records.record(id: rekey.credentialID) != nil)
        #expect(fixture.deviceBound.deleteCount() == deletesBefore)
        fixture.deviceBound.unlockAccount(current.keychainAccount)
    }

    @Test("Native connection APIs refuse wrong target, kind or field")
    func nativeConnectionBoundaries() async throws {
        let fixture = try await SkillConfigFixture.make()
        defer { fixture.cleanup() }
        try await fixture.saveSkill()
        let requirements = bridgeRequirements()
        let setup = try await fixture.service.saveConnectionPayload(
            skillID: "alpha",
            target: "local-ios",
            fieldKey: "bridge",
            connectionKind: "ios.bridge.local",
            payload: Data("pairing".utf8),
            reason: .initialSetup,
            requirements: requirements
        )
        // An SSH target is a different profile target and never sees the
        // native Bridge payload.
        await #expect(throws: SkillConfigurationError.credentialMissing("bridge")) {
            _ = try await fixture.service.readConnectionPayload(
                skillID: "alpha",
                target: "ssh:\(UUID().uuidString)",
                fieldKey: "bridge",
                connectionKind: "ios.bridge.local",
                requirements: requirements
            )
        }
        // A different connection kind is not this field.
        await #expect(throws: SkillConfigurationError.fieldNotConfigurable("bridge")) {
            _ = try await fixture.service.readConnectionPayload(
                skillID: "alpha",
                target: "local-ios",
                fieldKey: "bridge",
                connectionKind: "ssh.password",
                requirements: requirements
            )
        }
        // Wrong expected credential/revision on setup replacement.
        await #expect(throws: SkillConfigurationError.connectionBindingChanged) {
            _ = try await fixture.service.saveConnectionPayload(
                skillID: "alpha",
                target: "local-ios",
                fieldKey: "bridge",
                connectionKind: "ios.bridge.local",
                payload: Data("new-key".utf8),
                reason: .rekey,
                requirements: requirements,
                expectedCredentialID: UUID(),
                expectedRevision: setup.revision
            )
        }
        #expect(try await fixture.service.readConnectionPayload(
            skillID: "alpha",
            target: "local-ios",
            fieldKey: "bridge",
            connectionKind: "ios.bridge.local",
            requirements: requirements
        ).payload == Data("pairing".utf8))
    }

    @Test("Connections accept only device-bound credentials")
    func connectionsRequireDeviceBinding() async throws {
        let fixture = try await SkillConfigFixture.make()
        defer { fixture.cleanup() }
        try await fixture.saveSkill()
        let requirements = SkillConfigRequirements(fields: [
            SkillConfigFieldRequirement(
                key: "bridge",
                kind: .connection,
                required: true,
                connectionKind: "ios-bridge"
            )
        ])
        let ordinary = try await fixture.vault.capture(
            Data("ordinary-\(UUID().uuidString)".utf8),
            kind: .genericToken,
            owner: .vault,
            label: "Ordinary"
        )
        await #expect(throws: SkillConfigurationError.credentialNotAllowed("bridge")) {
            _ = try await fixture.service.bind(
                skillID: "alpha",
                inputs: [.init(fieldKey: "bridge", credentialID: ordinary.id)],
                requirements: requirements,
                runID: UUID()
            )
        }
        let outcome = try await fixture.service.bind(
            skillID: "alpha",
            inputs: [.init(fieldKey: "bridge", secret: "pairing-\(UUID().uuidString)")],
            requirements: requirements,
            runID: UUID()
        )
        let record = try await fixture.record(forField: "bridge")
        #expect(record.deviceBound)
        #expect(outcome.status.fields.first?.state == .validationRequired)
    }
}
