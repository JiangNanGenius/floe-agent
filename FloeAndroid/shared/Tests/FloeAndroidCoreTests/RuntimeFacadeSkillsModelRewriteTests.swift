// SPDX-License-Identifier: MPL-2.0
//
// RB-6 G02-SKILL-MODEL-REWRITE qualification tests. The REAL
// `FacadeSkillsModelRewriteRouter` + `FacadeSkillModelRewriter` run against
// the ORIGINAL store/gateway/owned-work registry; only the provider ADAPTER
// is controlled (`RB6ScriptedProviderAdapter`) so positive/cancel/error/
// no-configuration paths are deterministic without network, keys or cloud.
import XCTest
import Foundation
import Crypto
@testable import FloeAndroidCore
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloePersistence
import FloeSkills

// MARK: - Controlled provider adapter seam (test-only)

final class RB6ScriptedProviderAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIChatCompletions

    private let lock = NSLock()
    private var events: [AgentEvent] = []
    private var suspendForever = false
    private var streamCountValue = 0
    private var lastRequestValue: ProviderStreamRequest?
    private var lastCredentialsValue: ProviderCredentials?

    func script(events: [AgentEvent]) {
        lock.withLock {
            self.events = events
            self.suspendForever = false
        }
    }

    func scriptSuspension() {
        lock.withLock {
            self.events = []
            self.suspendForever = true
        }
    }

    var streamCount: Int { lock.withLock { streamCountValue } }
    var lastRequest: ProviderStreamRequest? { lock.withLock { lastRequestValue } }
    var lastCredentials: ProviderCredentials? { lock.withLock { lastCredentialsValue } }

    func stream(request: ProviderStreamRequest,
                credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
        let (scripted, suspend) = lock.withLock { () -> ([AgentEvent], Bool) in
            streamCountValue += 1
            lastRequestValue = request
            lastCredentialsValue = credentials
            return (events, suspendForever)
        }
        if suspend {
            return AsyncThrowingStream { _ in
                // Deliberately never yields: the consumed task's cancellation
                // must terminate the iterator (real cancellation contract).
            }
        }
        return AsyncThrowingStream { continuation in
            for event in scripted { continuation.yield(event) }
            continuation.finish()
        }
    }

    func listModels(provider: ProviderProfile,
                    credentials: ProviderCredentials) async throws -> [ModelProfile] {
        []
    }
}

final class RB6ProviderAdapterFactory: ProviderAdapterProviding, @unchecked Sendable {
    let adapter: RB6ScriptedProviderAdapter
    init(adapter: RB6ScriptedProviderAdapter) { self.adapter = adapter }
    func adapter(for profile: ProviderProfile) -> any ProviderAdapter { adapter }
}

// MARK: - Tests

final class RuntimeFacadeSkillsModelRewriteTests: XCTestCase {

    override func tearDown() async throws {
        await RB6TestFixture.shutdownCurrent()
    }

    private struct Harness {
        let fixture: RB6TestFixture
        let gateway: RB6ScriptedGateway
        let adapter: RB6ScriptedProviderAdapter
        let provider: ProviderProfile
        let model: ModelProfile
        let rewriter: FacadeSkillModelRewriter
        let domain: SkillsDomain
        let hub: RB6ScriptedHubTransport
    }

    private func makeHarness(_ id: String, seedModel: Bool = true) async throws -> Harness {
        let fixture = try await RB6TestFixture.make(id: id)
        let gateway = RB6ScriptedGateway()
        SecretGatewayRegistry.shared.register(gateway)
        let store = ModelConfigurationStore(database: fixture.database)
        let provider = ProviderProfile(
            kind: .custom, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://example.invalid/v1")!,
            displayName: "Controlled",
            secretRef: SecretReference(
                keychainAccount: ConfigSecretIdentity.providerAccount(
                    providerID: UUID()),
                synchronizable: false))
        // Rebuild with the real provider id so the canonical reference is exact.
        let providerWithSecret = ProviderProfile(
            id: provider.id, kind: .custom, wireProtocol: .openAIChatCompletions,
            baseURL: provider.baseURL, displayName: provider.displayName,
            secretRef: SecretReference(
                keychainAccount: ConfigSecretIdentity.providerAccount(
                    providerID: provider.id),
                synchronizable: false))
        let model = ModelProfile(providerID: providerWithSecret.id,
                                 remoteModelID: "controlled-text",
                                 displayName: "Controlled Text",
                                 limits: ModelLimits(contextTokens: 32_768,
                                                     maxOutputTokens: 8_192),
                                 capabilities: [.text],
                                 explicitCapabilities: [.text])
        if seedModel {
            try await store.saveProvider(providerWithSecret)
            try await store.saveModel(model, expected: nil)
            let reference = ConfigSecretIdentity.providerOpaqueReference(
                for: providerWithSecret.secretRef!)
            try await gateway.write(reference: reference,
                                    value: Data("synthetic-provider-key".utf8))
        }
        let adapter = RB6ScriptedProviderAdapter()
        let ownedWork = fixture.ownedWorkLifecycle()
        let router = FacadeSkillsModelRewriteRouter(
            database: fixture.database, gateway: SecretGatewayRegistry.shared,
            transportAdmission: RB6ProviderAdmission(admits: true),
            adapters: RB6ProviderAdapterFactory(adapter: adapter))
        let rewriter = FacadeSkillModelRewriter(routing: router, ownedWork: ownedWork)
        let hub = RB6ScriptedHubTransport()
        let domain = try SkillsDomain(services: .init(
            database: fixture.database,
            installationRoot: fixture.installationRoot,
            stagingRoot: fixture.stagingRoot,
            hostContext: fixture.hostContext,
            transport: hub,
            rewriter: rewriter,
            ownedWork: ownedWork,
            toolWork: FacadeToolWorkCoordinator(),
            registry: ToolRunnerRegistry()))
        return Harness(fixture: fixture, gateway: gateway, adapter: adapter,
                       provider: providerWithSecret, model: model,
                       rewriter: rewriter, domain: domain, hub: hub)
    }

    private static func rewriteJSON(markdown: String,
                                    manifest: [String: Any]? = nil) -> String {
        var object: [String: Any] = ["skillMarkdown": markdown]
        if let manifest { object["manifest"] = manifest }
        let data = try! JSONSerialization.data(withJSONObject: object,
                                               options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: no configured model is honest needsConfiguration

    func testUnconfiguredModelIsHonestNeedsConfiguration() async throws {
        let harness = try await makeHarness("rewrite-none", seedModel: false)
        do {
            _ = try await harness.rewriter.rewrite(
                markdown: "---\nname: x\ndescription: d\n---\n\nbody",
                manifestJSON: nil,
                modelID: UUID().uuidString)
            XCTFail("an unconfigured model must not rewrite")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .needsConfiguration)
            XCTAssertEqual(error.reason, "skillRewriteModelMissing")
        }
        XCTAssertEqual(harness.adapter.streamCount, 0)
        XCTAssertEqual(RuntimeOwnedWorkRegistry.shared.count(for: harness.fixture.epoch), 0,
                       "no owned lease may leak on a pre-effect refusal")
    }

    func testUnsupportedModelIsHonestNeedsConfiguration() async throws {
        let harness = try await makeHarness("rewrite-unsupported", seedModel: false)
        let store = ModelConfigurationStore(database: harness.fixture.database)
        try await store.saveProvider(harness.provider)
        // A media-only model is not a text rewrite route.
        let media = ModelProfile(providerID: harness.provider.id,
                                 remoteModelID: "image-1", displayName: "Image",
                                 limits: ModelLimits(contextTokens: 4_096,
                                                     maxOutputTokens: 512),
                                 capabilities: [.imageGeneration],
                                 explicitCapabilities: [.imageGeneration])
        try await store.saveModel(media, expected: nil)
        do {
            _ = try await harness.rewriter.rewrite(
                markdown: "---\nname: x\ndescription: d\n---\n\nbody",
                manifestJSON: nil, modelID: media.id.uuidString)
            XCTFail("a non-text model must not rewrite")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.reason, "skillRewriteModelUnsupported")
        }
        XCTAssertEqual(harness.adapter.streamCount, 0)
    }

    // MARK: configured supported model → real provider stream, no tools

    func testConfiguredModelRewritePositiveNoToolsAndRealLease() async throws {
        let harness = try await makeHarness("rewrite-positive")
        let rewritten = "---\nname: Rewritten Guide\ndescription: d\n---\n\nRewritten body."
        harness.adapter.script(events: [
            .textDelta(.init(text: Self.rewriteJSON(markdown: rewritten))),
            .completed(.init(stopReason: .endTurn)),
        ])
        let result = try await harness.rewriter.rewrite(
            markdown: "---\nname: Original\ndescription: d\n---\n\nbody",
            manifestJSON: nil, modelID: harness.model.id.uuidString)
        XCTAssertEqual(result.markdown, rewritten)
        XCTAssertNil(result.manifestJSON)
        XCTAssertEqual(harness.adapter.streamCount, 1)
        let request = try XCTUnwrap(harness.adapter.lastRequest)
        XCTAssertTrue(request.toolSchemas.isEmpty, "the rewrite is tool-free")
        XCTAssertEqual(request.allToolNames, [])
        XCTAssertEqual(request.messages.count, 2)
        XCTAssertEqual(request.provider.id, harness.provider.id)
        XCTAssertEqual(request.model.id, harness.model.id)
        // EXISTING canonical secret resolution supplied the request key.
        XCTAssertEqual(harness.adapter.lastCredentials?.apiKey, "synthetic-provider-key")
        XCTAssertEqual(RuntimeOwnedWorkRegistry.shared.count(for: harness.fixture.epoch), 0,
                       "the real owned lease is settled after the terminal")
    }

    // MARK: cancellation and typed errors

    func testRewriteCancellationPropagatesAndReleasesLease() async throws {
        let harness = try await makeHarness("rewrite-cancel")
        harness.adapter.scriptSuspension()
        let task = Task {
            try await harness.rewriter.rewrite(
                markdown: "---\nname: x\ndescription: d\n---\n\nbody",
                manifestJSON: nil, modelID: harness.model.id.uuidString)
        }
        // Wait until the provider stream is really open (attached lease).
        var waited = 0
        while harness.adapter.streamCount == 0, waited < 2_000 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            waited += 5
        }
        XCTAssertEqual(harness.adapter.streamCount, 1)
        XCTAssertEqual(RuntimeOwnedWorkRegistry.shared.count(for: harness.fixture.epoch), 1,
                       "the model request holds a REAL owned-work lease")
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancellation must terminate the rewrite")
        } catch {
            // CancellationError (direct adapter) is the honest terminal.
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        var released = false
        for _ in 0..<200 {
            if RuntimeOwnedWorkRegistry.shared.count(for: harness.fixture.epoch) == 0 {
                released = true
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(released, "the owned lease is released on the real terminal")
    }

    func testRewriteProviderErrorIsTypedAndRedacted() async throws {
        let harness = try await makeHarness("rewrite-error")
        harness.adapter.script(events: [
            .error(.init(kind: .server, providerMessage: "PROVIDER-SECRET-TEXT")),
        ])
        do {
            _ = try await harness.rewriter.rewrite(
                markdown: "---\nname: x\ndescription: d\n---\n\nbody",
                manifestJSON: nil, modelID: harness.model.id.uuidString)
            XCTFail("a provider error must refuse")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .runtimeUnavailable)
            XCTAssertEqual(error.reason, "skillRewriteModelError")
            XCTAssertFalse(String(describing: error).contains("PROVIDER-SECRET-TEXT"),
                           "provider text never crosses the domain boundary")
        }
        XCTAssertEqual(RuntimeOwnedWorkRegistry.shared.count(for: harness.fixture.epoch), 0)
    }

    func testRewriteOutputCapEnforced() async throws {
        let harness = try await makeHarness("rewrite-cap")
        let oversized = String(repeating: "a",
                               count: FacadeSkillModelRewriter.maximumOutputBytes + 1)
        harness.adapter.script(events: [
            .textDelta(.init(text: oversized)),
        ])
        do {
            _ = try await harness.rewriter.rewrite(
                markdown: "---\nname: x\ndescription: d\n---\n\nbody",
                manifestJSON: nil, modelID: harness.model.id.uuidString)
            XCTFail("the 512 KiB cap must refuse")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.code, .payloadTooLarge)
            XCTAssertEqual(error.reason, "skillRewriteOutput")
        }
        XCTAssertEqual(RuntimeOwnedWorkRegistry.shared.count(for: harness.fixture.epoch), 0)
    }

    // MARK: ordinary install without rewrite stays compatible

    func testFinderImportWithoutRewriteModelNeverCallsProvider() async throws {
        let harness = try await makeHarness("rewrite-none-import")
        harness.hub.finderEnvelopeBody = try RB6Package.finderEnvelopeJSON(
            skillID: "finder-guide",
            markdown: "---\nname: finder-guide\ndescription: d\n---\n\nbody",
            manifest: RB6Package.manifestJSON(id: "finder-guide",
                                              capabilities: [], tools: []))
        let projection = try await harness.domain.finderImport(
            urlText: "https://example.com/skill.json", rewriteModelID: nil)
        XCTAssertEqual(projection.skillID, "finder-guide")
        XCTAssertEqual(harness.adapter.streamCount, 0,
                       "no rewrite model ⇒ ordinary install path, no provider call")
    }

    func testFinderImportWithRewriteModelUsesRealAdapter() async throws {
        let harness = try await makeHarness("rewrite-import")
        let linuxManifest = RB6Package.manifestJSON(id: "finder-guide",
                                                    capabilities: [], tools: [])
        harness.hub.finderEnvelopeBody = try RB6Package.finderEnvelopeJSON(
            skillID: "finder-guide",
            markdown: "---\nname: finder-guide\ndescription: d\n---\n\nbody",
            manifest: linuxManifest)
        // The rewritten document keeps the package identity (name == id);
        // only the body/description may change (the validator enforces it).
        let rewritten = "---\nname: finder-guide\ndescription: rewritten\n---\n\nrewritten body"
        let manifestObject = try JSONSerialization.jsonObject(
            with: Data(linuxManifest.utf8)) as? [String: Any]
        harness.adapter.script(events: [
            .textDelta(.init(text: Self.rewriteJSON(markdown: rewritten,
                                                    manifest: manifestObject))),
            .completed(.init(stopReason: .endTurn)),
        ])
        let projection = try await harness.domain.finderImport(
            urlText: "https://example.com/skill.json",
            rewriteModelID: harness.model.id.uuidString)
        XCTAssertEqual(harness.adapter.streamCount, 1)
        XCTAssertEqual(projection.skillID, "finder-guide")
        let staged = try String(contentsOf: harness.fixture.installationRoot
            .appendingPathComponent("finder-guide/SKILL.md"), encoding: .utf8)
        XCTAssertTrue(staged.contains("rewritten body"),
                      "the staged package carries the model-rewritten body")
    }

    // MARK: the domain's shrink-only gate still rejects widening

    func testRewriteWideningIsRejectedByDomainValidation() async throws {
        let harness = try await makeHarness("rewrite-widen")
        let originalManifest = RB6Package.manifestJSON(id: "finder-guide",
                                                       capabilities: ["network"],
                                                       tools: [])
        harness.hub.finderEnvelopeBody = try RB6Package.finderEnvelopeJSON(
            skillID: "finder-guide",
            markdown: "---\nname: finder-guide\ndescription: d\n---\n\nbody",
            manifest: originalManifest)
        let widened = RB6Package.manifestJSON(id: "finder-guide",
                                              capabilities: ["network", "workspace.read"],
                                              tools: [])
        let widenedObject = try JSONSerialization.jsonObject(with: Data(widened.utf8))
        harness.adapter.script(events: [
            .textDelta(.init(text: Self.rewriteJSON(
                markdown: "---\nname: finder-guide\ndescription: d\n---\n\nbody",
                manifest: widenedObject as? [String: Any]))),
            .completed(.init(stopReason: .endTurn)),
        ])
        do {
            _ = try await harness.domain.finderImport(
                urlText: "https://example.com/skill.json",
                rewriteModelID: harness.model.id.uuidString)
            XCTFail("capability widening must be refused by the domain")
        } catch let error as ConfigDomainError {
            XCTAssertEqual(error.reason, "rewriteWidened")
        }
        let rows = try await SQLiteSkillStore(database: harness.fixture.database).all()
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: production transport binding is real (not permanently unavailable)

    func testPublicHubTransportFactoryIsRealAndAllowListed() throws {
        let transport = SkillsRemoteTransportComposition.makePublicHubTransport()
        XCTAssertTrue(transport is WebToolsSkillsRemoteTransport,
                      "production binds the qualified HTTP service, never the unavailable stub")
        XCTAssertThrowsError(try WebToolsSkillsRemoteTransport.validated(
            url: URL(string: "https://evil.example/skill.json")!))
        XCTAssertNoThrow(try WebToolsSkillsRemoteTransport.validated(
            url: URL(string: "https://raw.githubusercontent.com/x/y/z/SKILL.md")!))
    }
}

// MARK: - Test admission (provider transport gate)

struct RB6ProviderAdmission: ProviderTransportAdmitting {
    let admits: Bool
    var admitsCloudNetwork: Bool { admits }
}
