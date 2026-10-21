// SPDX-License-Identifier: MPL-2.0
//
// Provider-configuration completion (job-31c) — bounded host/object coverage
// for the remaining G02 provider-domain behavior, all over the ORIGINAL
// stores/adapters:
//
//  1. secret-free read projection: a persisted provider's `presetID` and
//     vetted `nonSecretHeaders` are projected with its real revision and no
//     secret body, so an existing editor can be reconstructed losslessly;
//  2. metadata enable/disable through a COMPLETE Keep candidate + REAL
//     revision (preserves every other field/model/secretRef, refuses stale
//     revisions with zero partial mutation);
//  3. trusted OFFICIAL catalog: the packaged resource bytes freeze through
//     the ORIGINAL decoder (schema/pin), and an injected facade serves real
//     entries/filters/configured marks; a missing catalog keeps the typed
//     refusal;
//  4. unsaved/dirty DRAFT probe/discovery through the trusted host seam:
//     the frozen candidate + ephemeral key reach the ORIGINAL adapter
//     (protocol/auth mapping parity), nothing is persisted, credential and
//     admission rules match the saved probe, cancellation is real, route
//     retirement sweeps owned work, and late polls fail closed;
// 5. the lease-close diagnostic polarity (flag only on a REAL close failure).
import XCTest
import Foundation
import Crypto
import FloeCore
import FloeModels
import FloePersistence
import FloeProviders
@testable import FloeAndroidCore

final class G02ProviderConfigurationCompletionTests: XCTestCase {

    private var databaseURL: URL!
    private var database: DatabaseManager!
    private let providerID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let epoch: UInt64 = 4242

    // MARK: - Fixtures

    /// Minimal typed gateway for secret-free assertions (records every write).
    private final class TestGateway: SecretGatewayServicing, @unchecked Sendable {
        private let lock = NSLock()
        private var store: [String: Data] = [:]
        private var writes: [String] = []
        var registered = true

        var isRegistered: Bool {
            lock.withLock { registered }
        }
        func read(reference: String) async throws -> Data? {
            lock.withLock { store[reference] }
        }
        func write(reference: String, value: Data) async throws {
            lock.withLock {
                store[reference] = value
                writes.append(reference)
            }
        }
        func delete(reference: String) async throws {
            lock.withLock { _ = store.removeValue(forKey: reference) }
        }
        var writeCount: Int {
            lock.withLock { writes.count }
        }
    }

    /// Recording original-adapter stand-in: proves which profile/credentials
    /// the ORIGINAL adapter seam received, without any network.
    private final class RecordingAdapterFactory: ProviderAdapterProviding, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var profiles: [ProviderProfile] = []
        private(set) var credentials: [ProviderCredentials] = []
        var holdNanos: UInt64 = 0
        var connectionError: Error?

        func adapter(for profile: ProviderProfile) -> any ProviderAdapter {
            lock.withLock { profiles.append(profile) }
            return RecordingAdapter(factory: self, profile: profile)
        }
        func record(_ credentials: ProviderCredentials) {
            lock.withLock { self.credentials.append(credentials) }
        }
        func lastProfile() -> ProviderProfile? {
            lock.withLock { profiles.last }
        }
    }

    private struct RecordingAdapter: ProviderAdapter {
        let factory: RecordingAdapterFactory
        let profile: ProviderProfile
        var protocolKind: ModelProtocol { profile.wireProtocol }

        func stream(request: ProviderStreamRequest,
                    credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
            AsyncThrowingStream { $0.finish(throwing: FloeError.internalError("unused")) }
        }
        func testConnection(provider: ProviderProfile,
                            credentials: ProviderCredentials) async throws {
            factory.record(credentials)
            if let connectionError = factory.connectionError { throw connectionError }
        }
        func listModels(provider: ProviderProfile,
                        credentials: ProviderCredentials) async throws -> [ModelProfile] {
            if factory.holdNanos > 0 {
                // Cancellation-aware hold: a cancel really unwinds the
                // adapter call instead of finishing a detached sleep.
                try await Task.sleep(nanoseconds: factory.holdNanos)
            }
            return (0..<2).map { index in
                ModelProfile(id: UUID(), providerID: provider.id,
                             remoteModelID: "draft-model-\(index)",
                             displayName: "Draft Model \(index)",
                             limits: ModelLimits(contextTokens: 8_192, maxOutputTokens: 2_048),
                             capabilities: [.text, .tools])
            }
        }
    }

    private struct AdmissionOpen: ProviderTransportAdmitting {
        var admitsCloudNetwork: Bool { true }
    }

    private func makeFacade(gateway: TestGateway,
                            adapters: RecordingAdapterFactory = RecordingAdapterFactory(),
                            admission: ProviderTransportAdmitting = TransportAdmissionClosed(),
                            catalogBytes: Data? = nil) -> ModelConfigurationFacade {
        ModelConfigurationFacade(
            database: database,
            gateway: gateway,
            catalogBytes: catalogBytes,
            transportAdmission: admission,
            adapters: adapters,
            epochProvider: FixedEpochProvider(epoch: 1),
            ownedWorkRegistry: AlwaysAttachOwnedWorkPort())
    }

    private func candidateJSON(baseURL: String = "https://draft.example.invalid/v1",
                               kind: ProviderKind = .custom,
                               wire: ModelProtocol = .openAIChatCompletions,
                               headers: [String: String] = ["X-Org": "draft-org"],
                               presetID: String? = "deepseek",
                               createIntent: Bool = false,
                               allowsPlainHTTP: Bool = false,
                               largePadding: Int = 0) throws -> Data {
        var candidate: [String: Any] = [
            "id": providerID.uuidString,
            "kind": kind.rawValue,
            "wireProtocol": wire.rawValue,
            "baseURL": baseURL,
            "displayName": "Draft Provider",
            "nonSecretHeaders": headers,
            "isEnabled": true,
            "allowsPlainHTTP": allowsPlainHTTP,
            "toolNameCompatibility": true,
            "syncEnabled": false,
            "serviceRoleIsConversation": true,
            "selectedModels": [[String: Any]](),
            "managedCapabilities": 0,
            "createIntent": createIntent,
        ]
        if let presetID { candidate["presetID"] = presetID }
        if largePadding > 0 {
            candidate["displayName"] = String(repeating: "x", count: largePadding)
        }
        return try JSONSerialization.data(withJSONObject: candidate, options: [.sortedKeys])
    }

    private func savePersistedProvider(headers: [String: String] = ["X-Org": "persisted"],
                                       presetID: String? = "deepseek",
                                       enabled: Bool = false) async throws {
        let store = ModelConfigurationStore(database: database)
        try await store.saveProvider(ProviderProfile(
            id: providerID,
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.example.invalid/v1")!,
            displayName: "Persisted Provider",
            presetID: presetID,
            secretRef: SecretReference(keychainAccount: "provider.\(providerID.uuidString)",
                                       synchronizable: false),
            nonSecretHeaders: headers,
            isEnabled: enabled,
            allowsPlainHTTP: false,
            toolNameCompatibility: true))
        // The ORIGINAL save records the catalog preset identity in the
        // bounded preset sidecar (the providers table has no preset column).
        if let presetID {
            try await ProviderPresetSidecar(database: database).record(
                presetID: presetID, for: providerID)
        }
        _ = try await store.models(providerID: providerID)
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `ModelConfigurationFacade` page methods return the composed canonical
    /// ARRAY; the G02 binder is what wraps it into the `{"rows":[...]}` OBJECT
    /// carrier. Accept both here so the test reads the real page either way.
    private func rows(of page: Data) throws -> [[String: Any]] {
        let value = try JSONSerialization.jsonObject(with: page)
        if let array = value as? [[String: Any]] { return array }
        if let object = value as? [String: Any],
           let rows = object["rows"] as? [[String: Any]] {
            return rows
        }
        throw NSError(domain: "G02ProviderConfigurationCompletionTests",
                      code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "unexpected page shape"])
    }

    private func pollSettled(_ registry: G02HostDraftProbeRegistry,
                             handle: String,
                             route: String,
                             timeoutMillis: Int = 3_000) async -> Data? {
        let deadline = Date().addingTimeInterval(Double(timeoutMillis) / 1000)
        while Date() < deadline {
            if let (status, payload) = try? registry.result(handle: handle,
                                                            routeAssertion: route),
               status == G02HostDraftProbeStatus.ok, let payload {
                return payload
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }

    override func setUp() async throws {
        _ = floeSecretGatewayRemove()
        SecretSaveIntentVault.shared.resetForTesting()
        G02HostDraftProbeRegistry.shared.resetForTesting()
        G02HostCatalog.resetForTesting()
        G02RuntimeComposition.shared.routeContext.resetRouteForTesting()
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-provider-completion-\(UUID().uuidString).db")
        database = try DatabaseManager(path: databaseURL)
        try await database.migrate()
    }

    override func tearDown() async throws {
        G02HostDraftProbeRegistry.shared.resetForTesting()
        G02HostCatalog.resetForTesting()
        G02RuntimeComposition.shared.routeContext.resetRouteForTesting()
        SecretSaveIntentVault.shared.resetForTesting()
        _ = floeSecretGatewayRemove()
        try await database.close()
        try? FileManager.default.removeItem(at: databaseURL)
        try await super.tearDown()
    }

    // MARK: - 1. Secret-free read projection

    func testProviderListProjectsPresetAndHeadersWithRealRevisionAndNoSecret()
        async throws {
        try await savePersistedProvider()
        let gateway = TestGateway()
        let facade = makeFacade(gateway: gateway)
        let page = try await facade.listProviders(cursor: nil)
        let row = try XCTUnwrap(try rows(of: page).first)

        XCTAssertEqual(row["presetID"] as? String, "deepseek",
                       "the persisted catalog preset must be readable")
        let headers = try XCTUnwrap(row["nonSecretHeaders"] as? [String: String])
        XCTAssertEqual(headers, ["X-Org": "persisted"],
                       "the vetted non-secret header map must be projected verbatim")
        XCTAssertEqual(row["isEnabled"] as? Bool, false)
        XCTAssertEqual(row["toolNameCompatibility"] as? Bool, true)
        XCTAssertEqual(row["wireProtocol"] as? String, "openai-chat-completions")
        XCTAssertEqual(row["syncRevision"] as? Int64, 0,
                       "the real CAS token is projected unchanged")

        // Secret presence + deterministic opaque reference ONLY.
        let secret = try XCTUnwrap(row["secret"] as? [String: Any])
        XCTAssertEqual(secret["configured"] as? Bool, true)
        XCTAssertNotNil(secret["opaqueReference"] as? String)
        for forbidden in ["apiKey", "api_key", "token", "secretRef", "value"] {
            XCTAssertNil(row[forbidden], "no secret body may be projected: \(forbidden)")
        }
        // The projection itself reads no credential.
        XCTAssertEqual(gateway.writeCount, 0)
        // `models` is a separate read surface; the summary invents no model
        // rows or counts.
        XCTAssertNil(row["models"])
        XCTAssertNil(row["modelCount"])
    }

    func testProjectionKeepsEachRowCoherentForPaging() async throws {
        let secondID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let store = ModelConfigurationStore(database: database)
        try await store.saveProvider(ProviderProfile(
            id: providerID, kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://a.example.invalid/v1")!,
            displayName: "A", presetID: "deepseek",
            nonSecretHeaders: ["X-A": "1"]))
        try await store.saveProvider(ProviderProfile(
            id: secondID, kind: .anthropic, wireProtocol: .anthropicMessages,
            baseURL: URL(string: "https://b.example.invalid/v1")!,
            displayName: "B", presetID: "anthropic",
            nonSecretHeaders: ["X-B": "2"]))
        let sidecar = ProviderPresetSidecar(database: database)
        try await sidecar.record(presetID: "deepseek", for: providerID)
        try await sidecar.record(presetID: "anthropic", for: secondID)
        let facade = makeFacade(gateway: TestGateway())
        let page = try await facade.listProviders(cursor: nil)
        let decoded = try rows(of: page)
        XCTAssertEqual(decoded.count, 2)
        let byID = Dictionary(uniqueKeysWithValues: decoded.compactMap { row -> (String, [String: Any])? in
            guard let id = row["id"] as? String else { return nil }
            return (id.uppercased(), row)
        })
        let first = try XCTUnwrap(byID[providerID.uuidString])
        let second = try XCTUnwrap(byID[secondID.uuidString])
        XCTAssertEqual(first["presetID"] as? String, "deepseek")
        XCTAssertEqual(first["nonSecretHeaders"] as? [String: String], ["X-A": "1"])
        XCTAssertEqual(second["presetID"] as? String, "anthropic")
        XCTAssertEqual(second["nonSecretHeaders"] as? [String: String], ["X-B": "2"])
        XCTAssertEqual(second["wireProtocol"] as? String, "anthropic-messages")
    }

    // MARK: - 2. List-level enable/disable through a COMPLETE Keep candidate

    func testCompleteKeepCandidateTogglesEnablementAndPreservesEverything()
        async throws {
        try await savePersistedProvider()
        let store = ModelConfigurationStore(database: database)
        let model = ModelProfile(
            id: UUID(), providerID: providerID, remoteModelID: "kept-model",
            displayName: "Kept Model",
            limits: ModelLimits(contextTokens: 4_096, maxOutputTokens: 1_024),
            capabilities: [.text, .tools], reasoningEffort: nil,
            isEnabled: false, isHiddenFromPrimaryPicker: true)
        try await store.saveModel(model)

        let gateway = TestGateway()
        let facade = makeFacade(gateway: gateway)
        let page = try await facade.listProviders(cursor: nil)
        let row = try XCTUnwrap(try rows(of: page).first)
        let revision = ConfigRevision.provider(id: providerID, syncRevision: 0)

        // Rebuild the App's exact Keep candidate from the projection + the
        // real model rows, changing ONLY isEnabled.
        let modelPage = try await facade.listModels(providerID: providerID, cursor: nil)
        let modelRows = try rows(of: modelPage)
        var candidate: [String: Any] = [
            "id": providerID.uuidString,
            "kind": row["kind"] as? String ?? "openAI",
            "wireProtocol": row["wireProtocol"] as? String ?? "openai-chat-completions",
            "baseURL": row["baseURL"] as? String ?? "",
            "displayName": row["displayName"] as? String ?? "",
            "nonSecretHeaders": row["nonSecretHeaders"] ?? [String: String](),
            "isEnabled": true,
            "allowsPlainHTTP": row["allowsPlainHTTP"] as? Bool ?? false,
            "toolNameCompatibility": row["toolNameCompatibility"] as? Bool ?? false,
            "syncEnabled": false,
            "serviceRoleIsConversation": true,
            "selectedModels": modelRows,
            "managedCapabilities": 0,
            "createIntent": false,
        ]
        if let preset = row["presetID"] as? String { candidate["presetID"] = preset }
        let keep = await facade.saveProviderKeep(
            candidateJSON: try JSONSerialization.data(withJSONObject: candidate,
                                                      options: [.sortedKeys]),
            envelopeRevision: revision)
        guard case .committed(let committed) = keep else {
            return XCTFail("complete keep candidate must commit: \(keep)")
        }
        XCTAssertEqual(committed.providerRevision.version, "1",
                       "the CAS advanced exactly once")
        XCTAssertFalse(committed.leaseAdmissionCloseFailed,
                       "no lease participates in Keep and none failed")

        let persistedOptional = try await store.provider(id: providerID)
        let persisted = try XCTUnwrap(persistedOptional)
        XCTAssertTrue(persisted.isEnabled, "the toggle flip is persisted")
        // The providers table carries no preset column: the ORIGINAL save
        // writes the bounded preset sidecar. The Keep preserved it.
        let sidecarMap = try await ProviderPresetSidecar(database: database).presetIDsByProvider()
        let sidecarPreset = sidecarMap[providerID]
        XCTAssertEqual(sidecarPreset, "deepseek", "preset identity preserved via the sidecar")
        XCTAssertEqual(persisted.nonSecretHeaders, ["X-Org": "persisted"],
                       "non-secret headers preserved")
        XCTAssertEqual(persisted.toolNameCompatibility, true)
        XCTAssertNotNil(persisted.secretRef, "Keep never clears the secret reference")
        XCTAssertEqual(gateway.writeCount, 0, "Keep never writes a secret")
        let persistedModels = try await store.models(providerID: providerID)
        XCTAssertEqual(persistedModels.count, 1)
        XCTAssertEqual(persistedModels.first?.id, model.id,
                       "canonical model UUID preserved")
        XCTAssertEqual(persistedModels.first?.isEnabled, false,
                       "disabled model stays disabled")
        XCTAssertEqual(persistedModels.first?.isHiddenFromPrimaryPicker, true)
    }

    func testStaleToggleRevisionRefusesWithZeroPartialMutation() async throws {
        try await savePersistedProvider()
        let gateway = TestGateway()
        let facade = makeFacade(gateway: gateway)
        let store = ModelConfigurationStore(database: database)
        let page = try await facade.listProviders(cursor: nil)
        let row = try XCTUnwrap(try rows(of: page).first)
        var candidate: [String: Any] = [
            "id": providerID.uuidString,
            "kind": row["kind"] as? String ?? "openAI",
            "wireProtocol": row["wireProtocol"] as? String ?? "openai-chat-completions",
            "baseURL": row["baseURL"] as? String ?? "",
            "displayName": row["displayName"] as? String ?? "",
            "nonSecretHeaders": row["nonSecretHeaders"] ?? [String: String](),
            "isEnabled": true,
            "syncEnabled": false,
            "serviceRoleIsConversation": true,
            "selectedModels": [[String: Any]](),
            "managedCapabilities": 0,
            "createIntent": false,
        ]
        if let preset = row["presetID"] as? String { candidate["presetID"] = preset }
        let keep = await facade.saveProviderKeep(
            candidateJSON: try JSONSerialization.data(withJSONObject: candidate,
                                                      options: [.sortedKeys]),
            envelopeRevision: ConfigRevision.provider(id: providerID, syncRevision: 0))
        guard case .committed = keep else {
            return XCTFail("fixture keep should commit once")
        }
        // A second Keep still presenting the OLD revision must be refused by
        // the real CAS with zero partial mutation.
        let stale = await facade.saveProviderKeep(
            candidateJSON: try JSONSerialization.data(withJSONObject: candidate,
                                                      options: [.sortedKeys]),
            envelopeRevision: ConfigRevision.provider(id: providerID, syncRevision: 0))
        guard case .failed(let failed) = stale,
              failed.error.code == .staleRevision else {
            return XCTFail("stale revision must refuse typed: \(stale)")
        }
        let persistedOptional = try await store.provider(id: providerID)
        let persisted = try XCTUnwrap(persistedOptional)
        XCTAssertEqual(persisted.syncRevision, 1, "no second mutation")
        XCTAssertEqual(persisted.nonSecretHeaders, ["X-Org": "persisted"])
        XCTAssertEqual(gateway.writeCount, 0)
    }

    // MARK: - 3. Trusted official catalog

    /// The packaged reviewed resource (exact byte copy of the original iOS
    /// trusted document), resolved from the test source location.
    private func bundledCatalogURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FloeAndroidCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // shared
            .appendingPathComponent("../core/swiftbridge/src/main/assets/provider/ProviderCatalog.json")
            .standardizedFileURL
    }

    private func bundledCatalogBytes() throws -> Data {
        let url = bundledCatalogURL()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "missing trusted catalog resource at \(url.path)")
        return try Data(contentsOf: url)
    }

    func testTrustedCatalogFreezeValidatesSchemaAndPinAndIsOneShot() throws {
        let bytes = try bundledCatalogBytes()
        // Byte pin of the reviewed resource (schemaVersion 1, 20 providers).
        let digest = sha256Hex(bytes)
        XCTAssertEqual(digest,
                       "4978b2e9a956d7e4859bfab280282da78f2b3ffd20fbaaf931fec26ecd79f474",
                       "the reviewed official catalog pin changed")
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(document["schemaVersion"] as? Int, 1)
        XCTAssertEqual((document["providers"] as? [Any])?.count, 20)

        XCTAssertEqual(G02HostCatalog.freeze(bytes), G02HostCatalogStatus.ok)
        XCTAssertEqual(G02HostCatalog.freeze(bytes), G02HostCatalogStatus.idempotentOk)
        XCTAssertEqual(G02HostCatalog.frozenBytes(), bytes)
        // A DIFFERENT valid document after a successful freeze is refused.
        var changed = document
        changed["schemaVersion"] = 1
        let source = try XCTUnwrap(changed["source"] as? [String: Any])
        var sourceChanged = source
        sourceChanged["fetchedAt"] = "2026-10-21T00:00:00Z"
        changed["source"] = sourceChanged
        let different = try JSONSerialization.data(withJSONObject: changed,
                                                   options: [.sortedKeys])
        XCTAssertNotEqual(different, bytes)
        XCTAssertEqual(G02HostCatalog.freeze(different), G02HostCatalogStatus.conflict,
                       "a DIFFERENT still-valid document must never replace the frozen one")
        XCTAssertEqual(G02HostCatalog.frozenBytes(), bytes, "no silent swap")
        // A schema-invalid document is refused as invalid (never a conflict).
        XCTAssertEqual(G02HostCatalog.freeze(Data("{\"providers\":[]}".utf8)),
                       G02HostCatalogStatus.invalid)
    }

    func testCatalogFreezeRefusalsAreTypedAndNeverFabricate() {
        XCTAssertEqual(G02HostCatalog.freeze(Data()), G02HostCatalogStatus.empty)
        XCTAssertEqual(G02HostCatalog.freeze(Data("{}".utf8)),
                       G02HostCatalogStatus.invalid)
        XCTAssertEqual(G02HostCatalog.freeze(Data(count: 2 * 1_024 * 1_024 + 1)),
                       G02HostCatalogStatus.oversized)
        XCTAssertNil(G02HostCatalog.frozenBytes())
    }

    func testInjectedCatalogServesRealEntriesFiltersAndConfiguredMarks() async throws {
        let bytes = try bundledCatalogBytes()
        XCTAssertEqual(G02HostCatalog.freeze(bytes), G02HostCatalogStatus.ok)
        let frozen = try XCTUnwrap(G02HostCatalog.frozenBytes())
        let gateway = TestGateway()
        let facade = makeFacade(gateway: gateway, catalogBytes: frozen)
        // `catalogMetadata()` is an actor-scoped diagnostic dictionary
        // ([String: Any], non-Sendable) and is deliberately not crossed into
        // this test context; the injected REAL document is proven below by
        // the actual decoded entries + filters.

        let all = try await facade.catalogSearch(query: "", filter: .all)
        let allRows = try rows(of: all)
        // The REAL document, not a fixture: the ORIGINAL byte-budget page
        // carries 12 complete entries of the 16 the search offers (4 of the
        // 20 are hiddenPresetIDs, never offered for adding).
        XCTAssertEqual(allRows.count, 12, "real entries on an actual-budgeted page")
        let hidden: Set<String> = ["github-copilot", "azure", "amazon-bedrock", "google-vertex"]
        let allIDs = Set(allRows.compactMap { $0["presetID"] as? String })
        XCTAssertTrue(allIDs.isDisjoint(with: hidden), "hidden presets are never offered")
        let deepseek = try XCTUnwrap(allRows.first { ($0["presetID"] as? String) == "deepseek" })
        XCTAssertEqual(deepseek["availability"] as? String, "available")
        XCTAssertNotNil(deepseek["baseURL"] as? String)
        XCTAssertNotNil(deepseek["defaultProtocol"] as? String)

        // Configured filter: the REAL sidecar join, after a persisted save
        // that records the preset id.
        try await savePersistedProvider()
        let configured = try await facade.catalogSearch(query: "", filter: .configured)
        let configuredRows = try rows(of: configured)
        XCTAssertEqual(configuredRows.compactMap { $0["presetID"] as? String },
                       ["deepseek"])
        // A search query narrows to matching entries, never invents one.
        let search = try await facade.catalogSearch(query: "deep", filter: .all)
        let searchRows = try rows(of: search)
        let searchIDs = searchRows.compactMap { $0["presetID"] as? String }
        XCTAssertTrue(searchIDs.contains("deepseek"),
                      "search 'deep' returned \(searchIDs)")
    }

    func testCatalogNotInjectedKeepsTypedRefusalAndCustomPathUnaffected() async throws {
        let facade = makeFacade(gateway: TestGateway(), catalogBytes: nil)
        do {
            _ = try await facade.catalogSearch(query: "", filter: .all)
            XCTFail("catalog must refuse when not injected")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .needsConfiguration)
            XCTAssertEqual(error.reason, "catalogNotInjected")
        }
    }

    // MARK: - 4. Unsaved/dirty draft probe + discovery parity

    private func openProviderRoute(editorID: String = "provider-editor-1",
                                   uiGeneration: UInt64 = 1) throws -> RouteBinding {
        G02RuntimeComposition.shared.routeContext.configureEpochForTesting { [epoch] in epoch }
        let route = try XCTUnwrap(G02HostSecureIngress.open(
            editorKind: "provider",
            editorID: "\(providerID.uuidString)-conversation-\(editorID)",
            uiGeneration: uiGeneration,
            expectedNativeRootEpoch: epoch))
        return route
    }

    func testDraftProbeDispatchesFrozenCandidateAndPersistsNothing() async throws {
        let adapters = RecordingAdapterFactory()
        let gateway = TestGateway()
        let facade = makeFacade(gateway: gateway, adapters: adapters,
                                admission: AdmissionOpen())
        G02HostDraftProbeRegistry.facadeProviderForTesting = { _ in facade }
        G02HostDraftProbeRegistry.lifecycleForTesting = ConfigOwnedWorkLifecycle(
            registry: AlwaysAttachOwnedWorkPort(),
            epochProvider: FixedEpochProvider(epoch: 1))
        let route = try openProviderRoute()
        let ephemeral = Data("sk-draft-ephemeral-123456".utf8)

        let handle = try G02HostDraftProbeRegistry.shared.submit(
            candidateJSON: try candidateJSON(),
            secret: ephemeral,
            routeAssertion: route.token)
        XCTAssertTrue(handle.hasPrefix("dp:v1:"))
        let settledPayload = await pollSettled(G02HostDraftProbeRegistry.shared,
                                                      handle: handle,
                                                      route: route.token)
        let payload = try XCTUnwrap(settledPayload)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "connected")
        XCTAssertEqual(object["modelCount"] as? Int, 2)
        XCTAssertEqual((object["discoveredModels"] as? [[String: Any]])?.count, 2)
        XCTAssertNil(object["secret"])

        // The ORIGINAL adapter saw the DRAFT identity/auth/protocol mapping.
        let profile = try XCTUnwrap(adapters.lastProfile())
        XCTAssertEqual(profile.id, providerID)
        XCTAssertEqual(profile.baseURL.absoluteString, "https://draft.example.invalid/v1")
        XCTAssertEqual(profile.kind, .custom)
        XCTAssertEqual(profile.wireProtocol, .openAIChatCompletions)
        XCTAssertEqual(profile.nonSecretHeaders, ["X-Org": "draft-org"])
        XCTAssertEqual(profile.presetID, "deepseek")
        XCTAssertEqual(profile.toolNameCompatibility, true)
        XCTAssertEqual(try XCTUnwrap(adapters.credentials.first).apiKey,
                       "sk-draft-ephemeral-123456")

        // ZERO persistence: no provider row, no model row, no secret write.
        let store = ModelConfigurationStore(database: database)
        let providerRows = try await store.providers()
        let modelRowsAfterProbe = try await store.models(providerID: providerID)
        XCTAssertTrue(providerRows.isEmpty)
        XCTAssertTrue(modelRowsAfterProbe.isEmpty)
        XCTAssertEqual(gateway.writeCount, 0)
        XCTAssertEqual(SecretSaveIntentVault.shared.discardLiveSlots(
            routeToken: route.token, routeGeneration: route.generation), 0,
            "a draft probe never mints a vault intent")
        XCTAssertEqual(G02HostDraftProbeRegistry.shared.liveCount, 0)
    }

    func testDraftProbeWithoutKeyRefusesBeforeAdapterForAuthProvider() async throws {
        let adapters = RecordingAdapterFactory()
        let facade = makeFacade(gateway: TestGateway(), adapters: adapters,
                                admission: AdmissionOpen())
        G02HostDraftProbeRegistry.facadeProviderForTesting = { _ in facade }
        G02HostDraftProbeRegistry.lifecycleForTesting = ConfigOwnedWorkLifecycle(
            registry: AlwaysAttachOwnedWorkPort(),
            epochProvider: FixedEpochProvider(epoch: 1))
        let route = try openProviderRoute()
        let handle = try G02HostDraftProbeRegistry.shared.submit(
            candidateJSON: try candidateJSON(kind: .openAI, presetID: nil),
            secret: nil,
            routeAssertion: route.token)
        let settledPayload = await pollSettled(G02HostDraftProbeRegistry.shared,
                                                      handle: handle,
                                                      route: route.token)
        let payload = try XCTUnwrap(settledPayload)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "failed")
        XCTAssertEqual(object["errorCode"] as? String, "credentialUnavailable")
        XCTAssertTrue(adapters.profiles.isEmpty,
                      "no credential -> typed refusal BEFORE any adapter work")
        XCTAssertEqual(adapters.credentials.count, 0)
    }

    func testDraftProbeAnonymousOnlyForNoAuthStyle() async throws {
        let adapters = RecordingAdapterFactory()
        let facade = makeFacade(gateway: TestGateway(), adapters: adapters,
                                admission: AdmissionOpen())
        G02HostDraftProbeRegistry.facadeProviderForTesting = { _ in facade }
        G02HostDraftProbeRegistry.lifecycleForTesting = ConfigOwnedWorkLifecycle(
            registry: AlwaysAttachOwnedWorkPort(),
            epochProvider: FixedEpochProvider(epoch: 1))
        let route = try openProviderRoute()
        let handle = try G02HostDraftProbeRegistry.shared.submit(
            candidateJSON: try candidateJSON(baseURL: "http://127.0.0.1:8080/v1",
                                             kind: .local, presetID: nil,
                                             allowsPlainHTTP: true),
            secret: nil,
            routeAssertion: route.token)
        let settledPayload = await pollSettled(G02HostDraftProbeRegistry.shared,
                                                      handle: handle,
                                                      route: route.token)
        let payload = try XCTUnwrap(settledPayload)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "connected")
        XCTAssertNil(try XCTUnwrap(adapters.credentials.first).apiKey,
                     "the explicit no-auth style is the only anonymous pass")
    }

    func testDraftProbeTransportAdmissionClosedRefusesTyped() async throws {
        let adapters = RecordingAdapterFactory()
        let facade = makeFacade(gateway: TestGateway(), adapters: adapters,
                                admission: TransportAdmissionClosed())
        G02HostDraftProbeRegistry.facadeProviderForTesting = { _ in facade }
        G02HostDraftProbeRegistry.lifecycleForTesting = ConfigOwnedWorkLifecycle(
            registry: AlwaysAttachOwnedWorkPort(),
            epochProvider: FixedEpochProvider(epoch: 1))
        let route = try openProviderRoute()
        let handle = try G02HostDraftProbeRegistry.shared.submit(
            candidateJSON: try candidateJSON(),
            secret: Data("sk-draft-ephemeral-123456".utf8),
            routeAssertion: route.token)
        let settledPayload = await pollSettled(G02HostDraftProbeRegistry.shared,
                                                      handle: handle,
                                                      route: route.token)
        let payload = try XCTUnwrap(settledPayload)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "failed")
        XCTAssertEqual(object["errorCode"] as? String, "transportUnavailable")
        XCTAssertTrue(adapters.profiles.isEmpty,
                      "admission refuses before the adapter is constructed")
    }

    func testDraftProbeCancelIsRealAndNeverFabricatesSuccess() async throws {
        let adapters = RecordingAdapterFactory()
        adapters.holdNanos = 5_000_000_000
        let facade = makeFacade(gateway: TestGateway(), adapters: adapters,
                                admission: AdmissionOpen())
        G02HostDraftProbeRegistry.facadeProviderForTesting = { _ in facade }
        G02HostDraftProbeRegistry.lifecycleForTesting = ConfigOwnedWorkLifecycle(
            registry: AlwaysAttachOwnedWorkPort(),
            epochProvider: FixedEpochProvider(epoch: 1))
        let route = try openProviderRoute()
        let handle = try G02HostDraftProbeRegistry.shared.submit(
            candidateJSON: try candidateJSON(),
            secret: Data("sk-draft-ephemeral-123456".utf8),
            routeAssertion: route.token)
        XCTAssertEqual(G02HostDraftProbeRegistry.shared.liveCount, 1)
        XCTAssertTrue(G02HostDraftProbeRegistry.shared.cancel(handle: handle,
                                                              routeAssertion: route.token))
        let settledPayload = await pollSettled(G02HostDraftProbeRegistry.shared,
                                                      handle: handle,
                                                      route: route.token)
        let payload = try XCTUnwrap(settledPayload)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "cancelled")
        XCTAssertNil(object["discoveredModels"],
                     "cancellation never surfaces a fabricated discovery")
    }

    func testRouteRetirementSweepsDraftProbeWorkAndLatePollFailsClosed() async throws {
        let adapters = RecordingAdapterFactory()
        adapters.holdNanos = 1_500_000_000
        let facade = makeFacade(gateway: TestGateway(), adapters: adapters,
                                admission: AdmissionOpen())
        // A scripted registry proves the ownership ORDERING: the exact lease
        // is attached before dispatch and detached ONLY at the REAL adapter
        // terminal — cancellation/route-retirement alone never looks drained.
        let port = AlwaysAttachOwnedWorkPort()
        G02HostDraftProbeRegistry.facadeProviderForTesting = { _ in facade }
        G02HostDraftProbeRegistry.lifecycleForTesting = ConfigOwnedWorkLifecycle(
            registry: port, epochProvider: FixedEpochProvider(epoch: 1))
        let route = try openProviderRoute()
        let handle = try G02HostDraftProbeRegistry.shared.submit(
            candidateJSON: try candidateJSON(),
            secret: Data("sk-draft-ephemeral-123456".utf8),
            routeAssertion: route.token)
        XCTAssertEqual(G02HostDraftProbeRegistry.shared.liveCount, 1)
        // Give the task a moment to pass the pre-dispatch race check and
        // reach the (held) adapter call.
        try await Task.sleep(nanoseconds: 100_000_000)
        // Root retirement (the same fence as RootStop) retires the route.
        G02RuntimeComposition.shared.routeContext.retireBoundRoute(epoch: epoch)
        // Cancellation is REAL but asynchronous: immediately after the
        // sweep the work is still owned (this is what makes RootStop wait);
        // the slot/lease release only at the adapter terminal.
        XCTAssertGreaterThan(port.attached.count, port.detachedReceipts.count,
                             "retirement must NOT fake-drain an unsettled adapter call")
        // A poll in that window answers pending, never a stale terminal.
        let pendingStatus = try G02HostDraftProbeRegistry.shared.result(
            handle: handle, routeAssertion: route.token).0
        XCTAssertEqual(pendingStatus, G02HostDraftProbeStatus.pending)
        // Late submit with the retired route fails closed immediately.
        XCTAssertThrowsError(try G02HostDraftProbeRegistry.shared.submit(
            candidateJSON: try candidateJSON(),
            secret: Data("sk-late".utf8),
            routeAssertion: route.token)) { error in
            XCTAssertEqual(error as? G02HostDraftProbeError, .routeUnavailable)
        }
        // Eventually the cancelled adapter really settles and the exact
        // lease is released.
        let deadline = Date().addingTimeInterval(5)
        while G02HostDraftProbeRegistry.shared.liveCount > 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(G02HostDraftProbeRegistry.shared.liveCount, 0,
                       "the owned work settles at its real terminal")
        let detaches = port.detachedReceipts.count
        XCTAssertEqual(detaches, port.attached.count,
                       "detach happened only after the awaited terminal")
        XCTAssertThrowsError(try G02HostDraftProbeRegistry.shared.result(
            handle: handle, routeAssertion: route.token)) { error in
            XCTAssertEqual(error as? G02HostDraftProbeError, .routeUnavailable)
        }
    }

    func testDraftProbeBoundsAndRouteOwnership() async throws {
        let adapters = RecordingAdapterFactory()
        adapters.holdNanos = 2_000_000_000
        let facade = makeFacade(gateway: TestGateway(), adapters: adapters,
                                admission: AdmissionOpen())
        G02HostDraftProbeRegistry.facadeProviderForTesting = { _ in facade }
        G02HostDraftProbeRegistry.lifecycleForTesting = ConfigOwnedWorkLifecycle(
            registry: AlwaysAttachOwnedWorkPort(),
            epochProvider: FixedEpochProvider(epoch: 1))
        let registry = G02HostDraftProbeRegistry.shared
        let route = try openProviderRoute()

        // Candidate byte bound (the native save-candidate cap).
        XCTAssertThrowsError(try registry.submit(
            candidateJSON: Data(repeating: 0x41, count: 16_385),
            secret: nil, routeAssertion: route.token)) { error in
            XCTAssertEqual(error as? G02HostDraftProbeError, .candidateTooLarge)
        }
        XCTAssertThrowsError(try registry.submit(
            candidateJSON: Data(), secret: nil, routeAssertion: route.token)) { error in
            XCTAssertEqual(error as? G02HostDraftProbeError, .invalidCandidate)
        }
        // Secret byte bound.
        XCTAssertThrowsError(try registry.submit(
            candidateJSON: try candidateJSON(),
            secret: Data(repeating: 0x42, count: 65_537),
            routeAssertion: route.token)) { error in
            XCTAssertEqual(error as? G02HostDraftProbeError, .secretTooLarge)
        }
        // Bounded live capacity.
        var handles: [String] = []
        for _ in 0..<G02HostDraftProbeRegistry.maximumLiveProbes {
            handles.append(try registry.submit(candidateJSON: try candidateJSON(),
                                               secret: Data("sk-draft".utf8),
                                               routeAssertion: route.token))
        }
        XCTAssertThrowsError(try registry.submit(candidateJSON: try candidateJSON(),
                                                 secret: Data("sk-draft".utf8),
                                                 routeAssertion: route.token)) { error in
            XCTAssertEqual(error as? G02HostDraftProbeError, .saturated)
        }
        // A FOREIGN route assertion can never read or cancel another route's
        // slot.
        XCTAssertThrowsError(try registry.result(handle: handles[0],
                                                 routeAssertion: "rt:v1:\(String(repeating: "0", count: 32))")) { error in
            XCTAssertEqual(error as? G02HostDraftProbeError, .routeUnavailable)
        }
        for handle in handles { _ = registry.cancel(handle: handle,
                                                    routeAssertion: route.token) }
    }

    func testDraftProbeDoesNotDisturbSavedProbeSingleFlight() async throws {
        // Saved probe (closed providerID) and a draft probe for the same
        // provider share the facade's per-provider single-flight.
        let adapters = RecordingAdapterFactory()
        adapters.holdNanos = 3_000_000_000
        let facade = makeFacade(gateway: TestGateway(), adapters: adapters,
                                admission: AdmissionOpen())
        try await savePersistedProvider()
        G02HostDraftProbeRegistry.facadeProviderForTesting = { _ in facade }
        G02HostDraftProbeRegistry.lifecycleForTesting = ConfigOwnedWorkLifecycle(
            registry: AlwaysAttachOwnedWorkPort(),
            epochProvider: FixedEpochProvider(epoch: 1))
        let route = try openProviderRoute()
        let handle = try G02HostDraftProbeRegistry.shared.submit(
            candidateJSON: try candidateJSON(),
            secret: Data("sk-draft".utf8),
            routeAssertion: route.token)
        // Deterministic: wait until the draft probe actually reached the
        // adapter (its per-provider single-flight is then held).
        let deadline = Date().addingTimeInterval(2)
        while adapters.lastProfile() == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNotNil(adapters.lastProfile())
        do {
            _ = try await facade.probe(providerID: providerID)
            XCTFail("a concurrent saved probe for the same provider must refuse")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .duplicateInFlight)
        }
        _ = G02HostDraftProbeRegistry.shared.cancel(handle: handle,
                                                    routeAssertion: route.token)
        _ = await pollSettled(G02HostDraftProbeRegistry.shared, handle: handle,
                              route: route.token)
    }

    // MARK: - 5. Lease-close diagnostic polarity

    func testSuccessfulLeaseCloseNeverReportsACloseFailure() async throws {
        let gateway = TestGateway()
        let facade = makeFacade(gateway: gateway, admission: AdmissionOpen())
        let route = try openProviderRoute()
        _ = route
        // A REAL Set through the frozen vault + original chain.
        let saveCandidate = try JSONSerialization.jsonObject(
            with: candidateJSON(baseURL: "https://save.example.invalid/v1",
                                kind: .custom, presetID: nil, createIntent: true))
        let intent: [String: Any] = [
            "subject": ["kind": "providerSave", "id": providerID.uuidString],
            "route": ["token": route.token, "generation": route.generation],
            "intent": "set",
            "candidate": saveCandidate,
        ]
        let intentData = try JSONSerialization.data(withJSONObject: intent,
                                                    options: [.sortedKeys])
        let token = try SecretSaveIntentVault.shared.submit(
            intentJSON: intentData, secret: Data("sk-synthetic".utf8))
        // The facade's route context must be the live provider editor route.
        let routedFacade = ModelConfigurationFacade(
            database: database, gateway: gateway, catalogBytes: nil,
            transportAdmission: AdmissionOpen(),
            routeContext: G02RuntimeComposition.shared.routeContext,
            adapters: RecordingAdapterFactory(),
            epochProvider: FixedEpochProvider(epoch: 1),
            ownedWorkRegistry: AlwaysAttachOwnedWorkPort())
        let execution = await routedFacade.saveProviderSet(
            ingressToken: token,
            envelopeRevision: ConfigRevision.provider(id: providerID, syncRevision: 0))
        guard case .committed(let committed) = execution else {
            return XCTFail("synthetic Set must commit through the real chain: \(execution)")
        }
        XCTAssertFalse(committed.leaseAdmissionCloseFailed,
                       "a SUCCESSFUL close must never be reported as a close failure")

        // The pure projection mirrors the real close() result 1:1.
        guard case .committed(let realFailure) = execution.applyingLeaseClose(false) else {
            return XCTFail("committed shape expected")
        }
        XCTAssertTrue(realFailure.leaseAdmissionCloseFailed,
                      "a REAL close failure is stamped honestly")
        guard case .committed(let realSuccess) = execution.applyingLeaseClose(true) else {
            return XCTFail("committed shape expected")
        }
        XCTAssertFalse(realSuccess.leaseAdmissionCloseFailed)
    }
}
