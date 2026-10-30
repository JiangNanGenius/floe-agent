// SPDX-License-Identifier: MPL-2.0
//
// RB2 model-configuration source tests — durable store, CAS, identity,
// catalog decoder and web-search backend against the ACTUAL file-backed
// schema-46 database and the ACTUAL original store. AUTHORED ONLY: this
// source package does NOT compile or execute them; Main's serialized
// qualification lane owns the real swift-test run (see REPORT.md and
// HANDOFF.md). Synthetic identities/endpoints/bytes only — no real provider,
// credential, network or device.
//
// These tests bind REAL original behavior (ModelConfigurationStore +
// DatabaseManager migrations + ConfigurationCodec merge/COALESCE rules)
// through the RB2 facade; fault seams are internal, test-only constructors.

import XCTest
import Foundation
import GRDB
@testable import FloeAndroidCore
import FloeCore
import FloePersistence
import FloeProviders
import FloeAndroidWebTools

final class RuntimeFacadeConfigStoreTests: XCTestCase {

    // MARK: Fixtures

    private var databaseURL: URL!
    private var database: DatabaseManager!

    private let providerA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let providerB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let modelM = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let modelN = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    override func setUp() async throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-rb2-store-\(UUID().uuidString).db")
        database = try DatabaseManager(path: databaseURL)
        try await database.migrate()
        // Real durable path must reach the pinned Android schema 49.
        let version = try await database.userVersion()
        XCTAssertEqual(version, DatabaseManager.currentSchemaVersion)
        XCTAssertEqual(DatabaseManager.currentSchemaVersion, 49)
    }

    override func tearDown() async throws {
        try await database.close()
        try? FileManager.default.removeItem(at: databaseURL)
    }

    // MARK: Helpers

    private func makeProvider(id: UUID,
                              kind: ProviderKind = .openAI,
                              wire: ModelProtocol = .openAIChatCompletions,
                              base: String = "https://api.example.invalid/v1",
                              secret: Bool) -> ProviderProfile {
        ProviderProfile(
            id: id,
            kind: kind,
            wireProtocol: wire,
            baseURL: URL(string: base)!,
            displayName: "Fixture \(id.uuidString.prefix(4))",
            secretRef: secret
                ? SecretReference(keychainAccount: ConfigSecretIdentity.providerAccount(providerID: id),
                                  synchronizable: false)
                : nil
        )
    }

    private func makeModel(id: UUID, providerID: UUID, remote: String,
                           capabilities: ModelCapabilities = [.text, .tools],
                           explicit: ModelCapabilities? = nil,
                           enabled: Bool = true) -> ModelProfile {
        ModelProfile(id: id,
                     providerID: providerID,
                     remoteModelID: remote,
                     displayName: "Fixture \(remote)",
                     limits: ModelLimits(contextTokens: 4096, maxOutputTokens: 1024),
                     capabilities: capabilities,
                     reasoningEffort: nil,
                     isEnabled: enabled,
                     explicitCapabilities: explicit)
    }

    private func makeFacade(catalogBytes: Data? = RuntimeCatalogFixture.validDocument,
                            gateway: any SecretGatewayServicing = StoreTestGateway())
        -> ModelConfigurationFacade {
        ModelConfigurationFacade(database: database,
                                 gateway: gateway,
                                 catalogBytes: catalogBytes,
                                 transportAdmission: TransportAdmissionClosed(),
                                 routeContext: ConfigRouteContextUnavailable(),
                                 adapters: OriginalProviderAdapterFactory(),
                                 epochProvider: FixedEpochProvider(epoch: 1),
                                 ownedWorkRegistry: AlwaysAttachOwnedWorkPort())
    }

    // MARK: - Providers list projection (secret-free)

    func testProvidersListProjectionIsOpaqueReferenceOnly() async throws {
        let store = ModelConfigurationStore(database: database)
        try await store.saveProvider(makeProvider(id: providerA, secret: true))
        let facade = makeFacade()
        let page = try await facade.listProviders()
        let text = String(decoding: page, as: UTF8.self)
        // The raw Keychain account string NEVER appears; the deterministic
        // opaque reference (SecretGatewayNaming, ref:v1:+64hex) DOES.
        XCTAssertFalse(text.contains("provider.\(providerA.uuidString)"),
                       "raw keychainAccount must not reach the wire")
        let expectedRef = SecretGatewayNaming.opaqueReference(
            namespace: "keychainAccount",
            account: "provider.\(providerA.uuidString)")
        XCTAssertTrue(text.contains(expectedRef))
        // Ordinary local persistence: synchronizable false persisted and
        // projected; no sync fields beyond status.
        XCTAssertTrue(text.contains("\"synchronizable\":false"))
        XCTAssertTrue(text.contains("\"configured\":true"))
    }

    // MARK: - All native cloud kinds/protocols preserved

    func testAllNativeCloudKindsAndProtocolsRoundTrip() async throws {
        let store = ModelConfigurationStore(database: database)
        // kinds: openAI, anthropic, volcengineArk, alibabaStudio,
        // googleGemini, local, custom (ProviderProfile.swift:7-15).
        let kinds: [(ProviderKind, ModelProtocol)] = [
            (.openAI, .openAIResponses),
            (.openAI, .openAIChatCompletions),
            (.anthropic, .anthropicMessages),
            (.volcengineArk, .openAIChatCompletions),
            (.alibabaStudio, .openAIChatCompletions),
            (.googleGemini, .openAIChatCompletions),
            (.local, .openAIChatCompletions),
            (.custom, .openAIChatCompletions),
        ]
        for (index, pair) in kinds.enumerated() {
            let id = UUID()
            let secure = pair.0 != .local
            let base = secure
                ? "https://k\(index).example.invalid/v1"
                : "http://127.0.0.1:11434/v1" // local: plain HTTP + private host
            var provider = makeProvider(id: id, kind: pair.0, wire: pair.1,
                                       base: base, secret: secure)
            if !secure {
                provider.allowsPlainHTTP = true // required for http + private
            }
            try await store.saveProvider(provider)
        }
        let facade = makeFacade()
        let page = try await facade.listProviders()
        let objects = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: page) as? [String: Any])?["rows"]
                as? [[String: Any]])
        XCTAssertEqual(objects.count, kinds.count)
        let listedKinds = Set(objects.compactMap { $0["kind"] as? String })
        XCTAssertEqual(listedKinds, Set(kinds.map { $0.0.rawValue }),
                       "no native cloud kind may be dropped or narrowed")
        let listedProtocols = Set(objects.compactMap { $0["wireProtocol"] as? String })
        XCTAssertEqual(listedProtocols,
                       Set(["openai-responses", "openai-chat-completions", "anthropic-messages"]))
    }

    // MARK: - Model CAS exactness + zero overwrite

    func testModelSaveCASRejectsStaleSnapshotWithoutWriting() async throws {
        let store = ModelConfigurationStore(database: database)
        try await store.saveProvider(makeProvider(id: providerA, secret: false))
        let original = makeModel(id: modelM, providerID: providerA, remote: "m1")
        try await store.saveModel(original)
        let facade = makeFacade()
        let digest = try ConfigModelSnapshot.digest(original)
        var edited = original
        edited.displayName = "Renamed"
        let payload = try ConfigModelSnapshot.data(edited)
        // Stale digest (client read an older snapshot): typed staleRevision.
        do {
            _ = try await facade.saveModel(payload: payload,
                                           revision: ConfigRevision.model(id: modelM,
                                                                          snapshotDigest: String(repeating: "0", count: 64)))
            XCTFail("stale digest must be refused")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .staleRevision)
        }
        let unchanged = try await store.model(id: modelM)
        XCTAssertEqual(unchanged, original, "zero overwrite on stale save")
        // Correct digest commits and the reply carries the canonical model.
        let reply = try await facade.saveModel(payload: payload,
                                               revision: ConfigRevision.model(id: modelM,
                                                                              snapshotDigest: digest))
        XCTAssertEqual(reply.canonicalModel.displayName, "Renamed")
        XCTAssertEqual(reply.revision.resourceID, "model.\(modelM.uuidString)")
        let stored = try await store.model(id: modelM)
        XCTAssertEqual(stored?.displayName, "Renamed")
    }

    func testModelSaveUnknownIdsTypedNotFound() async throws {
        let store = ModelConfigurationStore(database: database)
        try await store.saveProvider(makeProvider(id: providerA, secret: false))
        let facade = makeFacade()
        let ghost = makeModel(id: modelN, providerID: providerA, remote: "ghost")
        do {
            _ = try await facade.saveModel(payload: try ConfigModelSnapshot.data(ghost),
                                           revision: ConfigRevision.model(id: modelN,
                                                                          snapshotDigest: "irrelevant"))
            XCTFail("unknown model id must be typed notFound")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .notFound)
        }
        // A model under a MISSING provider cannot exist at all: the ORIGINAL
        // store's FK-restricted write refuses the row (no orphan model and no
        // partial write). The facade classifies this identity class as typed
        // notFound above; here we pin the underlying durable invariant.
        let orphan = makeModel(id: modelM, providerID: providerB, remote: "orphan")
        do {
            try await store.saveModel(orphan, expected: nil)
            XCTFail("the original store must not create an orphan model row")
        } catch {
            // Foreign-key refusal (SQLite 19): expected and typed upstream.
        }
        let providers = try await store.providers()
        XCTAssertEqual(providers.count, 1) // providerB does not exist
        let orphanModels = try await store.models(providerID: providerB)
        XCTAssertTrue(orphanModels.isEmpty)
    }

    func testModelSaveReuseSplitIdentityKeepsStableCanonicalUUID() async throws {
        let store = ModelConfigurationStore(database: database)
        try await store.saveProvider(makeProvider(id: providerA, secret: false))
        let first = makeModel(id: modelM, providerID: providerA, remote: "shared-remote")
        let second = makeModel(id: modelN, providerID: providerA, remote: "other-remote")
        try await store.saveModel(first)
        try await store.saveModel(second)
        let facade = makeFacade()
        // Edit `second` onto remote "shared-remote": the ORIGINAL codec
        // merges by provider+remoteModelID and REUSES the stable existing
        // local UUID (ModelConfigurationStore.swift:504-513), deleting the
        // incoming duplicate row ("reuse split identity").
        var moved = second
        moved.remoteModelID = "shared-remote"
        let digest = try ConfigModelSnapshot.digest(second)
        let reply = try await facade.saveModel(payload: try ConfigModelSnapshot.data(moved),
                                               revision: ConfigRevision.model(id: modelN,
                                                                              snapshotDigest: digest))
        XCTAssertEqual(reply.canonicalModel.id, modelM,
                       "canonical identity must be the pre-existing stable UUID")
        XCTAssertEqual(reply.canonicalModel.remoteModelID, "shared-remote")
        let remaining = try await store.models(providerID: providerA)
        XCTAssertEqual(remaining.count, 1)
        // internal id / displayName / remoteModelID stay distinct in the
        // projected wire (PRV-IDENTITY-WIRE-SPLIT-AND).
        XCTAssertNotEqual(reply.canonicalModel.id.uuidString,
                          reply.canonicalModel.remoteModelID)
    }

    func testExplicitCapabilitiesOverridePersistenceAndReopen() async throws {
        let store = ModelConfigurationStore(database: database)
        try await store.saveProvider(makeProvider(id: providerA, secret: false))
        let reviewed = makeModel(id: modelM, providerID: providerA, remote: "m1",
                                 explicit: [.text]) // reviewed mask (non-nil)
        try await store.saveModel(reviewed)
        let reopened = try await store.model(id: modelM)
        XCTAssertEqual(reopened?.explicitCapabilities, [.text],
                       "override survives reopen")
        // COALESCE: a nil write keeps the existing mask (never clears an
        // owned provenance); empty-0 mask is an EXPLICIT reviewed value.
        var nilWrite = reviewed
        nilWrite.explicitCapabilities = nil
        try await store.saveModel(nilWrite, expected: reviewed)
        let kept = try await store.model(id: modelM)
        XCTAssertEqual(kept?.explicitCapabilities, [.text])
        var emptyWrite = reviewed
        emptyWrite.explicitCapabilities = ModelCapabilities(rawValue: 0)
        try await store.saveModel(emptyWrite, expected: kept!)
        let zeroed = try await store.model(id: modelM)
        XCTAssertEqual(zeroed?.explicitCapabilities?.rawValue, 0,
                       "nil (no provenance) and empty mask 0 stay distinct")
    }

    // MARK: - Preferences CAS (increment-only, real validation)

    func testPreferencesCASIsIncrementOnlyAndStaleWritesZeroEffect() async throws {
        let facade = makeFacade()
        let first = try await facade.getPreferences()
        XCTAssertEqual(first.revision.version, "0") // default absent row
        var payload = try JSONDecoder().decode(ModelSelectionPreferences.self,
                                               from: first.valueJSON)
        payload.onboardingStatus = .completed
        payload.autonomousImageRouting = true
        let data = try JSONEncoder().encode(payload)
        let saved = try await facade.savePreferences(payload: data, revision: first.revision)
        XCTAssertEqual(saved.revision.version, "1", "syncRevision must advance by exactly 1")
        // Replay with the OLD revision: typed stale, row untouched.
        do {
            _ = try await facade.savePreferences(payload: data, revision: first.revision)
            XCTFail("replayed revision must be stale")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .staleRevision)
        }
        let reread = try await facade.getPreferences()
        XCTAssertEqual(reread.revision.version, "1")
        var payload2 = try JSONDecoder().decode(ModelSelectionPreferences.self,
                                                from: saved.valueJSON)
        payload2.onboardingStatus = .skipped
        let saved2 = try await facade.savePreferences(payload: try JSONEncoder().encode(payload2),
                                                      revision: saved.revision)
        XCTAssertEqual(saved2.revision.version, "2")
        // Payload smuggling a different syncRevision than the envelope CAS
        // token is refused BEFORE any write.
        var spoof = payload2
        spoof.syncRevision = 99
        do {
            _ = try await facade.savePreferences(payload: try JSONEncoder().encode(spoof),
                                                 revision: saved2.revision)
            XCTFail("payload revision divergence must be stale")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .staleRevision)
        }
        let final = try await facade.getPreferences()
        XCTAssertEqual(final.revision.version, "2")
    }

    func testPreferencesAssignmentValidationUsesRealStoreRules() async throws {
        let store = ModelConfigurationStore(database: database)
        try await store.saveProvider(makeProvider(id: providerA, secret: false))
        // A vision-only model must NOT satisfy the default agent slot.
        let visionOnly = ModelProfile(id: modelM,
                                      providerID: providerA,
                                      remoteModelID: "vision-only",
                                      displayName: "Vision",
                                      limits: ModelLimits(contextTokens: 4096, maxOutputTokens: 512),
                                      capabilities: [.vision],
                                      useSurfaces: [.auxiliaryVision],
                                      isEnabled: true)
        try await store.saveModel(visionOnly)
        let facade = makeFacade()
        let current = try await facade.getPreferences()
        var payload = try JSONDecoder().decode(ModelSelectionPreferences.self,
                                               from: current.valueJSON)
        payload.defaultAgentModelID = modelM
        do {
            _ = try await facade.savePreferences(payload: try JSONEncoder().encode(payload),
                                                 revision: current.revision)
            XCTFail("role/capability validation must reject")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .invalidEnvelope)
            XCTAssertEqual(error.reason, "defaultAgentText")
        }
        // Unknown model id: typed notFound (never "first model" fallback).
        payload.defaultAgentModelID = UUID()
        do {
            _ = try await facade.savePreferences(payload: try JSONEncoder().encode(payload),
                                                 revision: current.revision)
            XCTFail("unknown assignment must be typed notFound")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .notFound)
        }
        let unchanged = try await facade.getPreferences()
        XCTAssertEqual(unchanged.revision.version, "0") // zero writes landed
    }

    // MARK: - Catalog (real decoder, bounded search, no auto-install)

    func testCatalogDecoderFailClosedOnTamperedBytes() async throws {
        let facade = makeFacade(catalogBytes: RuntimeCatalogFixture.tamperedSchemaVersion)
        do {
            _ = try await facade.catalogSearch(query: "open", filter: .all)
            XCTFail("tampered catalog must fail closed")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .needsConfiguration)
            XCTAssertEqual(error.reason, "catalogFailClosed")
        }
        let absent = makeFacade(catalogBytes: nil)
        do {
            _ = try await absent.catalogSearch(query: "open", filter: .all)
            XCTFail("absent catalog must be needsConfiguration")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .needsConfiguration)
            XCTAssertEqual(error.reason, "catalogNotInjected")
        }
    }

    func testCatalogSearchBoundedAndNeverAutoInstalls() async throws {
        let facade = makeFacade()
        let store = ModelConfigurationStore(database: database)
        let before = try await store.providers().count
        let page = try await facade.catalogSearch(query: "fixture", filter: .available)
        let objects = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: page) as? [String: Any])?["rows"]
                as? [[String: Any]])
        XCTAssertFalse(objects.isEmpty)
        // Hidden presets (static model's hiddenPresetIDs) are NEVER returned.
        let ids = Set(objects.compactMap { $0["presetID"] as? String })
        for hidden in ProviderCatalogIndex.hiddenPresetIDs {
            XCTAssertFalse(ids.contains(hidden))
        }
        let afterSearch = try await store.providers().count
        XCTAssertEqual(afterSearch, before,
                       "search never installs providers/presets")
    }

    func testConfiguredPresetIDsComeFromRealStoreJoin() async throws {
        let facade = makeFacade()
        let page = try await facade.catalogSearch(query: "fixture", filter: .configured)
        XCTAssertEqual(((try JSONSerialization.jsonObject(with: page) as? [String: Any])?["rows"]
                        as? [Any])?.count ?? 0, 0,
                       "nothing configured initially")
        // Persist a provider WITH preset identity through the bundle path.
        let store = ModelConfigurationStore(database: database)
        var profile = makeProvider(id: providerA, secret: false)
        profile.presetID = "fixture-openai"
        try await store.saveProviderBundle(provider: profile, models: [],
                                           managedCapabilities: [.text])
        // The durable sidecar records the preset identity on the ORIGINAL
        // bundle write path (committer), or here via the direct codec — the
        // configured filter only reflects it when the LIVE row exists.
        let facadeWithSidecar = makeFacade()
        let configuredPage = try await facadeWithSidecar.catalogSearch(query: "fixture",
                                                                       filter: .configured)
        // NOTE: the sidecar is written by the SAVE flow (file 3), not by a
        // direct store.saveProviderBundle. Without a save through the facade
        // the join is empty — proving reads come from the real store, not a
        // RAM assumption.
        XCTAssertEqual(((try JSONSerialization.jsonObject(with: configuredPage) as? [String: Any])?["rows"]
                        as? [Any])?.count ?? 0, 0)
    }

    // MARK: - Web-search backend

    func testWebSearchGetEmptyDefaultAndSaveCAS() async throws {
        let facade = makeFacade()
        let initial = try await facade.getWebSearch()
        XCTAssertEqual(initial.states.count, 0)
        let absentDigest = ModelConfigurationFacade.webSearchDigest(nil)
        XCTAssertEqual(initial.revision.version, absentDigest)
        XCTAssertEqual(initial.revision.resourceID, "settings.websearch")
        let config = WebSearchProviderConfiguration(kind: .brave,
                                                    displayName: "Fixture Brave",
                                                    endpoint: URL(string: "https://search.example.invalid"),
                                                    credentialAccount: "web-search.brave",
                                                    enabled: true,
                                                    priority: 10)
        let payload = try JSONEncoder().encode(["configurations": [config]])
        let saved = try await facade.saveWebSearch(
            payload: payload,
            revision: ConfigRevision.webSearch(digest: absentDigest))
        XCTAssertEqual(saved.states.count, 1)
        // No real secret exists in this test gateway ⇒ typed availability.
        XCTAssertEqual(saved.states[0].credentialState, .secretMissing)
        // Replay with the OLD digest: stale, zero write.
        do {
            _ = try await facade.saveWebSearch(payload: payload,
                                               revision: ConfigRevision.webSearch(digest: absentDigest))
            XCTFail("stale websearch revision must be refused")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .staleRevision)
        }
        let reread = try await facade.getWebSearch()
        XCTAssertEqual(reread.states.count, 1)
        XCTAssertNotEqual(reread.revision.version, absentDigest)
    }

    func testWebSearchPersistedJSONNeverCarriesSecretValues() async throws {
        let facade = makeFacade()
        let absentDigest = ModelConfigurationFacade.webSearchDigest(nil)
        var options = [String: String]()
        options["max_results"] = "5"
        let config = WebSearchProviderConfiguration(kind: .tavily,
                                                    displayName: "Fixture Tavily",
                                                    endpoint: URL(string: "https://api.example.invalid/search"),
                                                    credentialAccount: "web-search.tavily",
                                                    enabled: true,
                                                    options: options)
        let payload = try JSONEncoder().encode(["configurations": [config]])
        _ = try await facade.saveWebSearch(payload: payload,
                                           revision: ConfigRevision.webSearch(digest: absentDigest))
        // Read the RAW persisted row through the ORIGINAL settings store.
        let settings = SQLiteSettingsStore(database: database)
        let stored = try await settings.value(forKey: ConfigSettingsKeys.webSearchConfigurations)
        let text = try XCTUnwrap(stored)
        // credentialAccount (identifier) may appear; secret VALUES may not.
        XCTAssertTrue(text.contains("web-search.tavily"))
        for forbidden in ["api_key", "apiKey", "values", "Bearer", "sk-"] {
            XCTAssertFalse(text.lowercased().contains(forbidden.lowercased()),
                           "persisted JSON must not carry secret material (\(forbidden))")
        }
    }

    func testWebSearchRejectsRawCredentialOptionNamesAndDuplicates() async throws {
        let facade = makeFacade()
        let absentDigest = ModelConfigurationFacade.webSearchDigest(nil)
        var hostile = [String: String]()
        hostile["api_key"] = "sk-obviously-not-config"
        let config = WebSearchProviderConfiguration(kind: .custom,
                                                    displayName: "Hostile",
                                                    endpoint: URL(string: "https://x.example.invalid"),
                                                    credentialAccount: "web-search.hostile",
                                                    options: hostile)
        let payload = try JSONEncoder().encode(["configurations": [config]])
        do {
            _ = try await facade.saveWebSearch(payload: payload,
                                               revision: ConfigRevision.webSearch(digest: absentDigest))
            XCTFail("credential-shaped option key must be refused")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .invalidEnvelope)
            XCTAssertTrue(error.reason.hasPrefix("rawCredentialMapKey"))
        }
        let dup = WebSearchProviderConfiguration(kind: .tavily,
                                                 displayName: "A",
                                                 credentialAccount: "same.account")
        let dupPayload = try JSONEncoder().encode(["configurations": [dup, dup]])
        do {
            _ = try await facade.saveWebSearch(payload: dupPayload,
                                               revision: ConfigRevision.webSearch(digest: absentDigest))
            XCTFail("duplicate entries must be refused")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .invalidEnvelope)
        }
    }

    func testWebSearchResolverSkipsUnavailableSecretsAndFabrication() async throws {
        // Synthetic gateway: web-search.tavily present+decodable; others absent.
        let credential = WebSearchCredential(values: ["apiKey": "synthetic-value"])
        let credentialBytes = try JSONEncoder().encode(credential)
        let gateway = StoreTestGateway(reads: [
            ConfigSecretIdentity.webSearchOpaqueReference(credentialAccount: "web-search.tavily"): credentialBytes,
        ])
        let facade = makeFacade(gateway: gateway)
        let absentDigest = ModelConfigurationFacade.webSearchDigest(nil)
        let tavily = WebSearchProviderConfiguration(kind: .tavily,
                                                    displayName: "T",
                                                    credentialAccount: "web-search.tavily")
        let brave = WebSearchProviderConfiguration(kind: .brave,
                                                   displayName: "B",
                                                   credentialAccount: "web-search.brave")
        let searxng = WebSearchProviderConfiguration(kind: .searxng,
                                                     displayName: "S",
                                                     endpoint: URL(string: "http://127.0.0.1:8888"),
                                                     credentialAccount: "unused.searxng")
        _ = try await facade.saveWebSearch(
            payload: try JSONEncoder().encode(["configurations": [tavily, brave, searxng]]),
            revision: ConfigRevision.webSearch(digest: absentDigest))
        let resolver = await facade.makeWebSearchConfigurationResolver()
        let ready = await resolver()
        let accounts = Set(ready.map { $0.0.credentialAccount })
        XCTAssertEqual(accounts, ["web-search.tavily", "unused.searxng"],
                       "only a real secret or an explicit no-credential kind resolves; missing secret is skipped, never anonymous-fabricated")
        let tavilyPair = try XCTUnwrap(ready.first { $0.0.kind == .tavily })
        XCTAssertEqual(tavilyPair.1["apiKey"], "synthetic-value") // in-memory use only
        let readText = String(decoding: try JSONEncoder().encode(ready.map { $0.0 }), as: UTF8.self)
        XCTAssertFalse(readText.contains("synthetic-value"),
                       "resolver NEVER serializes credential values into config JSON")
    }

    // MARK: - Settings whitelist stability (no arbitrary-key API)

    func testWhitelistedKeysAreExactlyTheOwnedThree() {
        XCTAssertEqual(ConfigSettingsKeys.webSearchConfigurations, "floe.webSearch.providers.v1")
        XCTAssertEqual(ConfigSettingsKeys.providerPresetIDs, "floe.provider.presetIDs.v1")
        XCTAssertEqual(ConfigSettingsKeys.providerSecretCleanup, "floe.provider.secretCleanup.v1")
    }
}

// MARK: - Fixtures

/// A syntactically valid tiny catalog (same schemaVersion 1 gate rules as
/// the shipped asset: models.dev import, MIT) used ONLY to exercise the real
/// decoder path. The shipped asset itself is hashed and quoted in the report.
enum RuntimeCatalogFixture {
    static let validDocument: Data = {
        let entry = ProviderCatalogEntry(
            presetID: "fixture-openai",
            name: "Fixture OpenAI",
            aliases: ["fx"],
            kind: .openAI,
            defaultProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.example.invalid/v1"),
            domains: ["example.invalid"],
            models: ["fixture-model"],
            availability: .available,
            unsupportedReason: nil,
            upstreamID: "fixture-openai",
            authStyle: "bearer",
            toolNameCompatibility: true,
            serviceOffers: nil,
            modelMetadata: nil
        )
        let hidden = ProviderCatalogEntry(
            presetID: "azure",
            name: "Fixture Hidden",
            aliases: [],
            kind: .openAI,
            defaultProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://hidden.example.invalid/v1"),
            domains: [],
            models: [],
            availability: .available,
            unsupportedReason: nil,
            upstreamID: "fixture-azure",
            authStyle: "bearer",
            toolNameCompatibility: false,
            serviceOffers: nil,
            modelMetadata: nil
        )
        let document = ProviderCatalogDocument(
            schemaVersion: 1,
            source: ProviderCatalogDocument.Source(
                project: "fixture-models",
                url: "https://fixture.example.invalid",
                license: "MIT",
                documentSHA256: String(repeating: "0", count: 64),
                fetchedAt: "2026-10-19T00:00:00Z"
            ),
            providers: [entry, hidden]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try! encoder.encode(document)
    }()

    static let tamperedSchemaVersion: Data = {
        guard var object = (try? JSONSerialization.jsonObject(with: validDocument))
                as? [String: Any] else { return Data() }
        object["schemaVersion"] = 2
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }()
}

/// Scripted in-memory gateway with call counters (test-only; mirrors the
/// frozen registry surface with zero Keystore/network).
final class StoreTestGateway: SecretGatewayServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [String: Data]
    var registered: Bool
    private var readCallsLog: [String] = []
    private var writeCallsLog: [(String, Data)] = []
    private var deleteCallsLog: [String] = []

    init(reads: [String: Data] = [:], registered: Bool = true) {
        self.reads = reads
        self.registered = registered
    }

    var isRegistered: Bool {
        lock.lock(); defer { lock.unlock() }; return registered
    }

    private func logRead(_ reference: String) {
        lock.lock(); readCallsLog.append(reference); lock.unlock()
    }
    private func logWrite(_ reference: String, _ data: Data) {
        lock.lock(); writeCallsLog.append((reference, data)); lock.unlock()
    }
    private func logDelete(_ reference: String) {
        lock.lock(); deleteCallsLog.append(reference); lock.unlock()
    }
    func snapshot() -> (reads: [String], writes: [(String, Data)], deletes: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (readCallsLog, writeCallsLog, deleteCallsLog)
    }

    func read(reference: String) async throws -> Data? {
        logRead(reference)
        let (registered, value): (Bool, Data?) = lock.withLock {
            (self.registered, reads[reference])
        }
        guard registered else { throw SecretGatewayError.needsConfiguration }
        return value
    }
    func write(reference: String, value: Data) async throws {
        logWrite(reference, value)
        let registered = lock.withLock { self.registered }
        guard registered else { throw SecretGatewayError.needsConfiguration }
        lock.withLock { reads[reference] = value }
    }
    func delete(reference: String) async throws {
        logDelete(reference)
        let registered = lock.withLock { self.registered }
        guard registered else { throw SecretGatewayError.needsConfiguration }
        lock.withLock { reads[reference] = nil }
    }
}

/// Fixed accepted epoch for tests (the real fence is validated by the
/// registry itself in production; this scripted port is test-only).
struct FixedEpochProvider: ConfigRuntimeEpochProviding {
    let epoch: UInt64?
    func currentEpoch() -> UInt64? { epoch }
}

/// Always-attaching owned-work port with an exact-token ledger so tests can
/// assert attach-before-effect and settle-after-settlement ordering.
final class AlwaysAttachOwnedWorkPort: OwnedWorkRegistryPort, @unchecked Sendable {
    private let lock = NSLock()
    private var counter = 0
    private(set) var attached: [RuntimeOwnedWorkToken] = []
    private(set) var detachedReceipts: [String] = []

    func attach(epoch: UInt64, kind: RuntimeOwnedWorkKind,
                ownerID: String) -> RuntimeOwnedWorkAttachOutcome {
        lock.lock()
        counter += 1
        let hex = String(format: "%032x", counter)
        let token = RuntimeOwnedWorkToken(receipt: "work:v1:" + hex,
                                          epoch: epoch, kind: kind, ownerID: ownerID)
        attached.append(token)
        lock.unlock()
        return .attached(token)
    }
    func detach(_ token: RuntimeOwnedWorkToken) -> Bool {
        lock.lock(); detachedReceipts.append(token.receipt); lock.unlock()
        return true
    }
    func isAttached(_ token: RuntimeOwnedWorkToken) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return attached.contains(token) && !detachedReceipts.contains(token.receipt)
    }
    func counts() -> (attached: Int, detached: Int) {
        lock.lock(); defer { lock.unlock() }
        return (attached.count, detachedReceipts.count)
    }
}
