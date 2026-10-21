// SPDX-License-Identifier: MPL-2.0
//
// RB2 model-configuration source tests — the frozen command binding surface
// and response projection. AUTHORED ONLY: NOT compiled/executed here.
//
// These cases pin the EXACT names of the 57-entry matrix subset RB2 binds,
// the closed payload grammar, the secret-free projections, and the typed
// refusal codes at the router boundary. Reuses the test doubles declared in
// RuntimeFacadeConfigStoreTests / RuntimeFacadeConfigIngressTests (same test
// target).

import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeCore
import FloePersistence
import FloeProviders
import FloeAndroidWebTools

final class RuntimeFacadeConfigBindingTests: XCTestCase {

    private var databaseURL: URL!
    private var database: DatabaseManager!

    override func setUp() async throws {
        _ = floeSecretGatewayRemove()
        SecretRequestMailbox.shared.resetForTesting()
        SecretSaveIntentVault.shared.resetForTesting()
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-rb2-binding-\(UUID().uuidString).db")
        database = try DatabaseManager(path: databaseURL)
        try await database.migrate()
    }

    override func tearDown() async throws {
        try await database.close()
        try? FileManager.default.removeItem(at: databaseURL)
    }

    private func makeRouter(gateway: SecretGatewayServicing = StoreTestGateway(),
                            catalogBytes: Data? = RuntimeCatalogFixture.validDocument,
                            admission: ProviderTransportAdmitting = TransportAdmissionClosed(),
                            adapters: any ProviderAdapterProviding = OriginalProviderAdapterFactory())
        -> ModelConfigurationCommandRouter {
        let facade = ModelConfigurationFacade(
            database: database,
            gateway: gateway,
            catalogBytes: catalogBytes,
            transportAdmission: admission,
            routeContext: ConfigRouteContextUnavailable(),
            adapters: adapters,
            epochProvider: FixedEpochProvider(epoch: 1),
            ownedWorkRegistry: AlwaysAttachOwnedWorkPort())
        return ModelConfigurationCommandRouter(facade: facade)
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - The frozen eleven names

    func testCommandNamesAreTheFrozenMatrixSubsetOnly() throws {
        let names = ModelConfigurationCommand.supportedCommandNames
        XCTAssertEqual(Set(names), Set([
            "config.providers.list", "config.provider.save",
            "config.provider.delete", "config.provider.probe",
            "config.models.list", "config.model.save",
            "config.catalog.search",
            "config.preferences.get", "config.preferences.save",
            "config.websearch.get", "config.websearch.save",
        ]), "RB2 binds EXACTLY the accepted config.* set — no additions")
        // Every name must exist in the frozen 57-entry matrix under the
        // applicationConfiguration scope (BridgeEnvelopeV3.swift:104-222).
        for name in names {
            XCTAssertTrue(BridgeV3.commandRules.contains { rule in
                rule.command == name && rule.scope == .applicationConfiguration
            }, "\(name) is not in the frozen matrix")
        }
        // Handler keys follow the frozen format.
        XCTAssertEqual(ModelConfigurationCommand.providerSave.bridgeV3HandlerKey,
                       BridgeV3.handlerKey(scope: .applicationConfiguration,
                                           command: "config.provider.save"))
    }

    // MARK: - Reads

    func testProvidersListThroughRouter() async throws {
        let store = ModelConfigurationStore(database: database)
        try await store.saveProvider(ProviderProfile(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.example.invalid/v1")!,
            displayName: "Router fixture",
            secretRef: SecretReference(keychainAccount: "provider.11111111-1111-1111-1111-111111111111",
                                       synchronizable: false)))
        let router = makeRouter()
        let response = await router.handle(command: "config.providers.list",
                                           envelope: [:])
        let object = try decode(response)
        XCTAssertEqual(object["state"] as? String, "completed")
        // Authorized page projection: {"rows":[…],nextCursor,hasMore}.
        let pageObject = try XCTUnwrap(object["value"] as? [String: Any])
        let value = try XCTUnwrap(pageObject["rows"] as? [[String: Any]])
        XCTAssertEqual(value.count, 1)
        let text = String(decoding: response, as: UTF8.self)
        XCTAssertFalse(text.contains("provider.11111111"),
                       "raw keychainAccount must not reach the wire")
    }

    func testCatalogSearchThroughRouterRejectsUnknownFilter() async throws {
        let router = makeRouter()
        let bad = await router.handle(command: "config.catalog.search",
                                      envelope: ["payload": ["query": "fix",
                                                            "filter": "everything"]])
        let object = try decode(bad)
        XCTAssertNil(object["state"])
        XCTAssertEqual(object["errorCode"] as? String, "invalidEnvelope")
        let ok = await router.handle(command: "config.catalog.search",
                                     envelope: ["payload": ["query": "fixture"]])
        XCTAssertEqual(try decode(ok)["state"] as? String, "completed")
    }

    func testRouterRejectsUnknownCommandsFailClosed() async throws {
        let router = makeRouter()
        let response = await router.handle(command: "config.provider.createV2",
                                           envelope: [:])
        let object = try decode(response)
        XCTAssertEqual(object["errorCode"] as? String, "unsupportedOperation",
                       "no invented command names gain an unbound handler")
    }

    // MARK: - Preferences through the router

    func testPreferencesGetThenSaveRoundTripWithRevisions() async throws {
        let router = makeRouter()
        let get = await router.handle(command: "config.preferences.get", envelope: [:])
        let getObject = try decode(get)
        let completed = try XCTUnwrap(getObject["state"] as? String)
        XCTAssertEqual(completed, "completed")
        let value = try XCTUnwrap(getObject["value"] as? [String: Any])
        let revision = try XCTUnwrap(value["revision"] as? [String: Any])
        let envelopeRevision: [String: Any] = [
            "resourceID": try XCTUnwrap(revision["resourceID"] as? String),
            "version": try XCTUnwrap(revision["version"] as? String),
        ]
        let preferences = try XCTUnwrap(value["preferences"] as? [String: Any])
        var edited = preferences
        edited["onboardingStatus"] = "completed"
        let save = await router.handle(command: "config.preferences.save",
                                       envelope: ["revision": envelopeRevision,
                                                  "payload": edited])
        let savedObject = try decode(save)
        XCTAssertEqual(savedObject["state"] as? String, "completed")
        let savedValue = try XCTUnwrap(savedObject["value"] as? [String: Any])
        let savedRevision = try XCTUnwrap(savedValue["revision"] as? [String: Any])
        XCTAssertEqual(savedRevision["version"] as? String, "1")
        // Replay with the OLD envelope revision: stale, zero write.
        let replay = await router.handle(command: "config.preferences.save",
                                         envelope: ["revision": envelopeRevision,
                                                    "payload": edited])
        let replayObject = try decode(replay)
        XCTAssertEqual(replayObject["errorCode"] as? String, "staleRevision")
    }

    // MARK: - model.save projection keeps id/displayName/remote distinct

    func testModelSaveProjectionCarriesCanonicalRevisionToken() async throws {
        let providerID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let modelID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let store = ModelConfigurationStore(database: database)
        try await store.saveProvider(ProviderProfile(
            id: providerID, kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.example.invalid/v1")!,
            displayName: "P"))
        let model = ModelProfile(id: modelID, providerID: providerID,
                                 remoteModelID: "router-model",
                                 displayName: "Router Model",
                                 limits: ModelLimits(contextTokens: 2048, maxOutputTokens: 512),
                                 capabilities: [.text])
        try await store.saveModel(model)
        let router = makeRouter()
        let digest = try ConfigModelSnapshot.digest(model)
        var edited = model
        edited.displayName = "Renamed by router"
        var payload = try decode(ConfigModelSnapshot.data(edited))
        payload["capabilities"] = {
            let data = try! JSONEncoder().encode(ModelCapabilities.text)
            return try! JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        }()
        let save = await router.handle(command: "config.model.save",
                                       envelope: ["payload": payload,
                                                  "revision": ["resourceID": "model.\(modelID.uuidString)",
                                                               "version": digest]])
        let object = try decode(save)
        XCTAssertEqual(object["state"] as? String, "completed")
        let value = try XCTUnwrap(object["value"] as? [String: Any])
        let revision = try XCTUnwrap(value["revision"] as? [String: Any])
        XCTAssertEqual(revision["resourceID"] as? String, "model.\(modelID.uuidString)")
        XCTAssertEqual((revision["version"] as? String)?.count, 64)
        let projected = try XCTUnwrap(value["model"] as? [String: Any])
        XCTAssertEqual(projected["id"] as? String, modelID.uuidString)
        XCTAssertEqual(projected["remoteModelID"] as? String, "router-model")
        XCTAssertEqual(projected["displayName"] as? String, "Renamed by router")
    }

    // MARK: - provider.save form grammar + disposition projection

    func testProviderSaveRequiresClosedFormsOnly() async throws {
        let router = makeRouter()
        // Unknown secretIntent.
        let unknown = await router.handle(command: "config.provider.save",
                                          envelope: ["payload": ["secretIntent": "swap"]])
        let unknownObject = try decode(unknown)
        XCTAssertEqual(unknownObject["errorCode"] as? String, "invalidEnvelope")
        // set without a token.
        let noToken = await router.handle(command: "config.provider.save",
                                          envelope: ["payload": ["secretIntent": "set"]])
        XCTAssertEqual(try decode(noToken)["errorCode"] as? String, "invalidEnvelope")
        // keep with an inline raw key field is refused by name.
        let smuggled = await router.handle(command: "config.provider.save",
                                           envelope: ["payload": ["secretIntent": "keep",
                                                                  "apiKey": "sk-inline"]])
        XCTAssertEqual(try decode(smuggled)["errorCode"] as? String, "invalidEnvelope")
        let smuggledText = String(decoding: smuggled, as: UTF8.self)
        XCTAssertTrue(smuggledText.contains("rawCredentialInputRejected"))
        // candidate smuggled INSIDE the keep object next to a token: the
        // closed form whitelist refuses the extra key.
        let both = await router.handle(command: "config.provider.save",
                                       envelope: ["payload": ["secretIntent": "set",
                                                              "ingressToken": "int:v1:00000000000000000000000000000000",
                                                              "candidate": ["id": UUID().uuidString]]])
        XCTAssertEqual(try decode(both)["errorCode"] as? String, "invalidEnvelope")
    }

    func testFailureProjectionCarriesHonestDispositionFields() async throws {
        let gateway = IngressTestGateway()
        gateway.nextWriteError = SecretBackendError.abandoned
        let router = makeRouter(gateway: gateway)
        // A well-formed token that was never submitted ⇒ notFound at consume
        // — but we want the post-consume failure shape, so submit first.
        SecretSaveIntentVault.shared.resetForTesting()
        let candidate: [String: Any] = [
            "id": "11111111-1111-1111-1111-111111111111",
            "kind": "openAI",
            "wireProtocol": "openai-chat-completions",
            "baseURL": "https://api.example.invalid/v1",
            "displayName": "Projection fixture",
            "syncEnabled": false,
            "selectedModels": [],
            "managedCapabilities": try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(ModelCapabilities.text),
                options: [.fragmentsAllowed]),
            "serviceRoleIsConversation": true,
            "createIntent": true,
        ]
        let intent: [String: Any] = [
            "subject": ["kind": "providerSave", "id": candidate["id"]!],
            "route": ["token": "route-a", "generation": 5],
            "intent": "set",
            "candidate": candidate,
        ]
        let intentData = try JSONSerialization.data(withJSONObject: intent, options: [.sortedKeys])
        var json = intentData
        json.append(0)
        var tokenBuffer = [CChar](repeating: 0, count: 64)
        var status: Int32 = -1
        let secret = Data("sk-projection".utf8)
        json.withUnsafeBytes { jsonRaw in
            secret.withUnsafeBytes { secretRaw in
                tokenBuffer.withUnsafeMutableBufferPointer { buffer in
                    status = floeSecretSaveIntentSubmit(
                        jsonRaw.bindMemory(to: CChar.self).baseAddress,
                        secretRaw.bindMemory(to: UInt8.self).baseAddress,
                        Int32(secret.count), buffer.baseAddress, 40)
                }
            }
        }
        XCTAssertEqual(status, 0)
        // The route context of THIS router is unavailable ⇒ the save is
        // refused before consuming; rebuild a route-aware facade instead.
        let facade = ModelConfigurationFacade(
            database: database,
            gateway: gateway,
            catalogBytes: nil,
            transportAdmission: TransportAdmissionClosed(),
            routeContext: FixedRouteContext(token: "route-a", generation: 5),
            epochProvider: FixedEpochProvider(epoch: 1),
            ownedWorkRegistry: AlwaysAttachOwnedWorkPort())
        let routeAwareRouter = ModelConfigurationCommandRouter(facade: facade)
        let response = await routeAwareRouter.handle(command: "config.provider.save",
                                                     envelope: ["payload": [
                                                         "secretIntent": "set",
                                                         "ingressToken": String(cString: tokenBuffer),
                                                     ]])
        let object = try decode(response)
        // The wire must NEVER say "saved" here; disposition is explicit.
        XCTAssertNil((object["value"] as? [String: Any])?["state"])
        let value = object
        XCTAssertEqual(value["errorCode"] as? String, "runtimeUnavailable")
        XCTAssertTrue(((value["reason"] as? String) ?? "").hasPrefix("secretOutcomeUnknown"))
        XCTAssertEqual(value["secretDisposition"] as? String, "outcomeUnknown")
        XCTAssertEqual(value["databaseRowWritten"] as? Bool, false)
        let text = String(decoding: response, as: UTF8.self)
        XCTAssertFalse(text.contains("sk-projection"),
                       "the raw secret NEVER appears in the terminal frame")
    }

    // MARK: - websearch through the router

    func testWebsearchGetRevisionAndClosedSaveGrammar() async throws {
        let router = makeRouter()
        let get = await router.handle(command: "config.websearch.get", envelope: [:])
        let getObject = try decode(get)
        XCTAssertEqual(getObject["state"] as? String, "completed")
        let value = try XCTUnwrap(getObject["value"] as? [String: Any])
        let revision = try XCTUnwrap(value["revision"] as? [String: Any])
        XCTAssertEqual(revision["resourceID"] as? String, "settings.websearch")
        let badSave = await router.handle(command: "config.websearch.save",
                                          envelope: ["revision": revision,
                                                     "payload": ["configs": []]])
        XCTAssertEqual(try decode(badSave)["errorCode"] as? String, "invalidEnvelope")
    }

    // MARK: - probe via the router

    func testProbeRefusesAdmissionClosedThroughRouter() async throws {
        let providerID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let store = ModelConfigurationStore(database: database)
        try await store.saveProvider(ProviderProfile(
            id: providerID, kind: .local, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "http://127.0.0.1:11434/v1")!,
            displayName: "Probe fixture", allowsPlainHTTP: true))
        let router = makeRouter()
        let response = await router.handle(command: "config.provider.probe",
                                           envelope: ["payload": ["providerID": providerID.uuidString]])
        let object = try decode(response)
        XCTAssertEqual(object["state"] as? String, "completed",
                       "the probe terminal outcome is always reported typed")
        let value = try XCTUnwrap(object["value"] as? [String: Any])
        XCTAssertEqual(value["status"] as? String, "failed")
        XCTAssertTrue(((value["failureReason"] as? String) ?? "").hasPrefix("transportUnavailable"))
    }

    // MARK: - Cursor grammar on list reads

    func testCursorBeyondEndIsTypedRefusalNotSilentEmpty() async throws {
        let router = makeRouter()
        let response = await router.handle(command: "config.providers.list",
                                           envelope: ["cursor": ["sequence": "9999"]])
        let object = try decode(response)
        XCTAssertEqual(object["errorCode"] as? String, "invalidEnvelope")
        let negative = await router.handle(command: "config.providers.list",
                                           envelope: ["cursor": ["sequence": "-1"]])
        // Negative cursors are unreadable → the view treats them as absent
        // (nil cursor), which is a normal page-0 read, never an error.
        XCTAssertEqual(try decode(negative)["state"] as? String, "completed")
    }
}
