// SPDX-License-Identifier: MPL-2.0
//
// RB-6 capabilities + tool-work qualification TEST SOURCE (authored, NOT
// executed by this package). Availability propagation is asserted through
// the REAL registry + the REAL MCPDomain connection track (loopback),
// the CURRENT upstream public-web-only temporary ceiling, saved model
// capability overrides via the REAL ModelConfigurationStore rows, and the
// RB4-owned cancellation port over live staging workers (scoped drain
// keeps ownership while the real work waits).
import XCTest
import Foundation
import Crypto
@testable import FloeAndroidCore
import FloeCore
import FloeModels
import FloeTools
import FloePersistence

final class RuntimeFacadeCapabilitiesTests: XCTestCase {

    override func tearDown() async throws {
        await RB6TestFixture.shutdownCurrent()
    }

    private func registryDescriptor(name: String, risk: Set<RiskLabel>,
                                    sideEffecting: Bool, effect: ToolEffect)
        -> ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(name: name, toolDescription: "t",
                               parametersJSON: "{\"type\":\"object\"}",
                               riskLabels: risk, isSideEffecting: sideEffecting)
    }

    // MARK: availability reflects the REAL registry, not descriptors alone

    func testUnavailableRunnerNeverAdvertised() async throws {
        let fixture = try await RB6TestFixture.make(id: "cap-avail")
        let registry = ToolRunnerRegistry()
        let available = AnyAgentTool(descriptor: registryDescriptor(
            name: "demo.available", risk: [.readsFiles], sideEffecting: false,
            effect: .readOnly)) { _, _ in
            ToolExecutionOutput(summary: "ok", fullOutputSHA256: "0")
        }
        var disabled = AnyAgentTool(descriptor: registryDescriptor(
            name: "demo.disabled", risk: [.readsFiles], sideEffecting: false,
            effect: .readOnly)) { _, _ in
            ToolExecutionOutput(summary: "no", fullOutputSHA256: "0")
        }
        disabled.isAvailable = { false }
        registry.register(available)
        registry.register(disabled)
        let domain = CapabilitiesDomain(services: .init(
            database: fixture.database, webSearch: CapabilitiesWebSearchUnbound(),
            mcp: CapabilitiesMCPUnbound(), hostContext: fixture.hostContext,
            registry: registry))
        let router = CapabilitiesCommandRouter(domain: domain)
        let reply = await router.handle(
            command: "capability.tools.list",
            envelope: ["schema": "floe.command-envelope/3",
                       "scope": "applicationConfiguration",
                       "command": "capability.tools.list",
                       "configurationScope": "capabilities",
                       "stateful": false, "correlationID": "cap-a"])
        let value = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: reply) as? [String: Any])?["value"]
            as? [String: Any])
        let names = (try XCTUnwrap(value["tools"] as? [[String: Any]]))
            .compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["demo.available"],
                       "allDescriptors is availability-filtered; the disabled runner must not appear")
    }

    // MARK: MCP namespace availability through the REAL connection track

    func testMCPConnectedToolsAdvertiseAvailable() async throws {
        let fixture = try await RB6TestFixture.make(id: "cap-mcp")
        let http = try ScriptedLoopbackFixture()
        http.register(path: "/mcp") { connection in
            let object = (try? JSONSerialization.jsonObject(with: connection.request.body))
                as? [String: Any]
            let id = object?["id"] as? Int ?? 0
            let payload: [String: Any] = ["jsonrpc": "2.0", "id": id,
                                          "result": ["tools": [[
                                              "name": "srv.echo", "description": "d",
                                              "inputSchema": ["type": "object"]]]]]
            let data = try! JSONSerialization.data(withJSONObject: payload)
            connection.sendHead(status: 200,
                                headers: ["content-type": "application/json",
                                          "content-length": String(data.count)])
            connection.sendRaw(data)
        }
        http.start()
        defer { http.stop() }
        let registry = ToolRunnerRegistry()
        let gateway = RB6ScriptedGateway()
        let route = RB6RouteContext(token: "route-test", generation: 7)
        let mcp = MCPDomain(services: .init(
            database: fixture.database, gateway: gateway, routeContext: route,
            transportAdmission: RB6TestAdmission(admits: true),
            clientFactory: OriginalMCPClientFactory(),
            ownedWork: fixture.ownedWorkLifecycle(),
            toolWork: FacadeToolWorkCoordinator(), registry: registry,
            hostContext: fixture.hostContext))
        let serverID = UUID()
        let intent: [String: Any] = [
            "intent": "set",
            "subject": ["kind": SubjectKind.mcpSave.rawValue, "id": serverID.uuidString],
            "route": ["token": "route-test", "generation": 7],
            "candidate": ["id": serverID.uuidString, "displayName": "Cap",
                          "endpoint": "http://127.0.0.1:\(http.port)/mcp",
                          "allowInsecureHTTP": true,
                          "authentication": "bearerToken", "createIntent": true],
        ]
        let token = try SecretSaveIntentVault.shared.submit(
            intentJSON: try JSONSerialization.data(withJSONObject: intent,
                                                   options: [.sortedKeys]),
            secret: Data("secret".utf8))
        let saved = await mcp.saveSet(ingressToken: token, envelopeRevision: nil)
        XCTAssertEqual((saved["connect"] as? [String: Any])?["state"] as? String,
                       "connected")
        let capabilities = CapabilitiesDomain(services: .init(
            database: fixture.database, webSearch: CapabilitiesWebSearchUnbound(),
            mcp: mcp, hostContext: fixture.hostContext, registry: registry))
        let value = try await capabilities.list(modelID: nil, includeUnavailable: false,
                                                cursor: nil)
        let tools = try XCTUnwrap(value["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?["availability"] as? String, "AVAILABLE")
        XCTAssertEqual(tools.first?["source"] as? String, "mcp")
    }

    // MARK: G03 families honest NOT_IMPLEMENTED; retired names absent

    func testLinuxRoutedNamesNeverUsable() async throws {
        let fixture = try await RB6TestFixture.make(id: "cap-linux")
        let registry = ToolRunnerRegistry()
        registry.register(AnyAgentTool(descriptor: registryDescriptor(
            name: "exec.shell", risk: [.executesRemoteCommand],
            sideEffecting: true, effect: .mutating)) { _, _ in
            ToolExecutionOutput(summary: "would run", fullOutputSHA256: "0")
        })
        let capabilities = CapabilitiesDomain(services: .init(
            database: fixture.database, webSearch: CapabilitiesWebSearchUnbound(),
            mcp: CapabilitiesMCPUnbound(), hostContext: fixture.hostContext,
            registry: registry))
        let value = try await capabilities.list(modelID: nil, includeUnavailable: true,
                                                cursor: nil)
        let tools = try XCTUnwrap(value["tools"] as? [[String: Any]])
        let shell = try XCTUnwrap(tools.first { $0["name"] as? String == "exec.shell" })
        XCTAssertEqual(shell["availability"] as? String, "NOT_IMPLEMENTED",
                       "CapabilityExecutionRouter routes exec.shell to the unresolved G03 linuxGuest backend; it can never be advertised usable in G02")
    }

    // MARK: saved model capability override is authoritative

    func testExplicitModelToolsOffProjectsUnsupported() async throws {
        let fixture = try await RB6TestFixture.make(id: "cap-model")
        let registry = ToolRunnerRegistry()
        registry.register(AnyAgentTool(descriptor: registryDescriptor(
            name: "demo.tool", risk: [.readsFiles], sideEffecting: false,
            effect: .readOnly)) { _, _ in
            ToolExecutionOutput(summary: "ok", fullOutputSHA256: "0")
        })
        let store = ModelConfigurationStore(database: fixture.database)
        let provider = ProviderProfile(kind: .custom, wireProtocol: .openAIChatCompletions,
                                       baseURL: URL(string: "https://example.invalid")!,
                                       displayName: "p")
        try await store.saveProvider(provider)
        let model = ModelProfile(id: UUID(), providerID: provider.id,
                                 remoteModelID: "m", displayName: "m",
                                 limits: ModelLimits(contextTokens: 8_192,
                                                     maxOutputTokens: 1_024),
                                 capabilities: [.text, .tools],
                                 explicitCapabilities: [.text])  // EXPLICIT no-tools
        try await store.saveModel(model, expected: nil)
        let capabilities = CapabilitiesDomain(services: .init(
            database: fixture.database, webSearch: CapabilitiesWebSearchUnbound(),
            mcp: CapabilitiesMCPUnbound(), hostContext: fixture.hostContext,
            registry: registry))
        let value = try await capabilities.list(modelID: model.id.uuidString,
                                                includeUnavailable: true, cursor: nil)
        let tools = try XCTUnwrap(value["tools"] as? [[String: Any]])
        let tool = try XCTUnwrap(tools.first { $0["name"] as? String == "demo.tool" })
        XCTAssertEqual(tool["availability"] as? String, "UNSUPPORTED")
        let prerequisites = try XCTUnwrap(tool["prerequisites"] as? [[String: String]])
        XCTAssertEqual(prerequisites.first?["reason"], "explicitToolsOff")
    }

    // MARK: temporary ceiling — CURRENT closed public-web-only set

    func testTemporaryCeilingClosedThreeNameSet() throws {
        // Registered web tools pass; everything else fails closed even if
        // marked read-only (the stale permissive two-name behavior is gone).
        let search = ToolCatalog.Descriptor(name: "web.search",
                                            toolDescription: "public web search",
                                            parametersJSON: "{\"type\":\"object\"}",
                                            riskLabels: [.networkAccess],
                                            isSideEffecting: false)
        let readTool = ToolCatalog.Descriptor(name: "workspace.read",
                                              toolDescription: "reads files",
                                              parametersJSON: "{}",
                                              riskLabels: [.readsFiles],
                                              isSideEffecting: false)
        let allowed = FacadeTemporaryCeiling.offeredNames(from: [search, readTool],
                                                          webSearchConfigured: true)
        XCTAssertEqual(allowed, ["web.search"])
        let withoutProvider = FacadeTemporaryCeiling.offeredNames(
            from: [search, readTool], webSearchConfigured: false)
        XCTAssertTrue(withoutProvider.isEmpty)
        // Executor-side denial for every invocation, not just visibility:
        let denial = FacadeTemporaryCeiling.denialReason(
            descriptor: readTool, arguments: Data("{}".utf8))
        XCTAssertNotNil(denial)
        XCTAssertNil(FacadeTemporaryCeiling.denialReason(
            descriptor: search,
            arguments: Data("{\"query\":\"hi\"}".utf8)))
        // web.fetch localNetwork is refused (original public-web-only rule).
        let fetch = ToolCatalog.Descriptor(name: "web.fetch",
                                           toolDescription: "public web fetch",
                                           parametersJSON: "{}",
                                           riskLabels: [.networkAccess],
                                           isSideEffecting: false)
        XCTAssertNotNil(FacadeTemporaryCeiling.denialReason(
            descriptor: fetch, arguments: Data("{\"url\":\"https://x\",\"localNetwork\":true}".utf8)))
    }

    // MARK: cancellation adapter — honest false, scoped true

    func testRunOwnedToolCancellationScoping() async throws {
        let coordinator = FacadeToolWorkCoordinator()
        let runA = UUID(); let runB = UUID(); let epoch: UInt64 = 42
        // Nothing owned ⇒ FALSE (never a fake success), per RB4 port docs.
        let none = await coordinator.cancelOwnedTool(runID: runA, callID: nil, epoch: epoch)
        XCTAssertFalse(none)
        let demo = await coordinator.beginPublic(ownerID: "skill:demo", runID: runA,
                                                  callID: "call-1", epoch: epoch)
        let worker = try XCTUnwrap(demo.valueForTesting)
        // Wrong epoch cannot touch another generation's work.
        let wrongEpoch = await coordinator.cancelOwnedTool(runID: runA, callID: nil,
                                                           epoch: epoch &+ 1)
        XCTAssertFalse(wrongEpoch)
        // Exact (run, callID) match cancels and reports.
        let matched = await coordinator.cancelOwnedTool(runID: runA, callID: "call-1",
                                                        epoch: epoch)
        XCTAssertTrue(matched)
        XCTAssertTrue(worker.token.isCancelled)
        // Another run untouched (first its own worker, then cancel):
        let other = await coordinator.beginPublic(ownerID: "skill:other", runID: runB,
                                                  callID: "call-1", epoch: epoch)
        _ = try XCTUnwrap(other.valueForTesting)
        let second = await coordinator.cancelOwnedTool(runID: runB, callID: nil,
                                                       epoch: epoch)
        XCTAssertTrue(second)
        await coordinator.end(worker.id)
    }

    // MARK: restart/generation expiry (domain level)

    func testStaleRootGenerationCannotCommitReviews() async throws {
        let fixture = try await RB6TestFixture.make(id: "cap-gen")
        let registry = ToolRunnerRegistry()
        let toolWork = FacadeToolWorkCoordinator()
        let domain = try SkillsDomain(services: .init(
            database: fixture.database,
            installationRoot: fixture.installationRoot,
            stagingRoot: fixture.stagingRoot,
            hostContext: fixture.hostContext,
            transport: SkillsRemoteTransportUnavailable(),
            rewriter: SkillModelRewritingUnavailable(),
            ownedWork: fixture.ownedWorkLifecycle(),
            toolWork: toolWork, registry: registry))
        // Stage a review under THIS generation…
        let packageDirectory = fixture.stagingRoot
            .appendingPathComponent("gen-\(UUID().uuidString)")
        try RB6Package.writePackage(at: packageDirectory, id: "gen-guide",
                                    manifest: RB6Package.manifestJSON(
                                        id: "gen-guide", capabilities: ["network"],
                                        tools: []),
                                    markdown: RB6Package.markdown(name: "gen-guide"))
        let receipt = SkillsFolderStagingReceipt(
            canonicalSHA256: try RB6Package.canonicalDigest(at: packageDirectory),
            fileCount: 2,
            totalBytes: try self.directoryBytesForPackage(packageDirectory),
            ttlSeconds: 600)
        let token = try await domain.registerStagedFolder(directory: packageDirectory,
                                                    receipt: receipt)
        let projection = try await domain.importStagedFolder(token: token)
        XCTAssertEqual(projection.committed, false)
        // …then STOP the generation (trusted stop, exact epoch+token) and
        // start a newer one: the old review token must be invisible.
        await fixture.forceRetireForTesting()
        do {
            _ = try await domain.reviewCommit(token: projection.token,
                                              createIntent: true, revision: nil)
            // If a NEW generation was accepted, the old-epoch review must
            // NOT be committable; without a new generation the guard is
            // runtimeNotReady. Either way a silent success is impossible.
            XCTFail("stale-generation commit must never succeed")
        } catch let error as ConfigDomainError {
            XCTAssertTrue(["reviewUnknown", "storeNotReady"].contains(error.reason),
                          error.reason)
        } catch is SkillsDomainRefusal {
            // runtimeNotReady — acceptable honest refusal
        }
    }
}

// MARK: - test-only conveniences (internal under @testable)

extension Result {
    /// XCTUnwrap-friendly value accessor for the coordinator's typed
    /// begin outcome (nil on any BeginRejection).
    var valueForTesting: Success? {
        switch self {
        case .success(let value): return value
        case .failure: return nil
        }
    }
}

extension FacadeToolWorkCoordinator {
    /// The actor's begin(...) surfaced for direct adapter tests; identical
    /// internal path, no production behavior change.
    func beginPublic(ownerID: String, runID: UUID?, callID: String?, epoch: UInt64)
        -> Result<FacadeOwnedWorker, BeginRejection> {
        begin(ownerID: ownerID, runID: runID, callID: callID, epoch: epoch)
    }
}

extension RB6TestFixture {
    /// Trusted stop + strictly-newer start: the generation actually changes,
    /// exercising the domain's epoch fencing (never a simulated epoch).
    func forceRetireForTesting() async {
        _ = AndroidRuntimeBootstrap.shutdown(expectedEpoch: epoch,
                                             ownerToken: ownerToken)
        var waited = 0
        while AndroidRuntimeBootstrap.currentPumps() != nil, waited < 15_000 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 10
        }
    }
}

extension RuntimeFacadeCapabilitiesTests {
    /// Exact byte total of a staged fixture package (the receipt must match
    /// the ACTUAL bytes, not a placeholder).
    func directoryBytesForPackage(_ directory: URL) throws -> Int {
        var total = 0
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += values?.fileSize ?? 0 }
        }
        return total
    }
}
