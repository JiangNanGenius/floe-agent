// SPDX-License-Identifier: MPL-2.0
//
// RB-6 MCP qualification TEST SOURCE (authored, NOT executed by this
// package). Everything runs through the PUBLIC production adapters: the
// MCPDomain/OriginalMCPClientFactory with the REAL MCPRemoteClient actor,
// the REAL SecretSaveIntentVault one-shot lease (submit under @testable —
// the same internal API the shipped C ABI forwards to), the scripted
// canonical-namespace gateway, and the accepted runtime generation. Network
// peers are 127.0.0.1 scripted fixtures ONLY (existing
// ScriptedLoopbackFixture); the scripted admission-open exists only in
// this test target — shipped seams default closed.
//
// Coverage (task contract): create/connect/disconnect/reconnect/remove,
// actual tool counts + ORIGINAL namespacing, cancel under the exact live
// generation, late-discovery fencing, credential-before-dispatch,
// Set/Keep/Clear origin binding + one-shot lease honesty, CV-R4 ambiguous
// write outcomeUnknown, no plaintext secret on the wire, malformed /
// oversize / no-redirect / SSE / legacy-session-era strictness, disabled
// server unregister, per-tool toggle without reconnect.
import XCTest
import Foundation
import Crypto
@testable import FloeAndroidCore
import FloeCore
import FloeTools
import FloePersistence

final class RuntimeFacadeMCPTests: XCTestCase {

    override func tearDown() async throws {
        await RB6TestFixture.shutdownCurrent()
    }

    private struct Harness {
        let fixture: RB6TestFixture
        let http: ScriptedLoopbackFixture
        let gateway: RB6ScriptedGateway
        let domain: MCPDomain
        let router: MCPCommandRouter
        let registry: ToolRunnerRegistry
    }

    private func makeHarness(_ id: String, gatewayRegistered: Bool = true) async throws
        -> Harness {
        let fixture = try await RB6TestFixture.make(id: id)
        let http = try ScriptedLoopbackFixture()
        http.start()
        let registry = ToolRunnerRegistry()
        let gateway = RB6ScriptedGateway(registered: gatewayRegistered)
        let route = RB6RouteContext(token: "route-test", generation: 7)
        let domain = MCPDomain(services: .init(
            database: fixture.database, gateway: gateway, routeContext: route,
            transportAdmission: RB6TestAdmission(admits: true),
            clientFactory: OriginalMCPClientFactory(),
            ownedWork: fixture.ownedWorkLifecycle(),
            toolWork: FacadeToolWorkCoordinator(),
            registry: registry, hostContext: fixture.hostContext))
        return Harness(fixture: fixture, http: http, gateway: gateway, domain: domain,
                       router: MCPCommandRouter(domain: domain, routeContext: route),
                       registry: registry)
    }

    private func endpoint(_ harness: Harness) -> String {
        "http://127.0.0.1:\(harness.http.port)/mcp"
    }

    /// The ORIGINAL origin-bound account rule (SkillsView.swift:594-607):
    /// mcp.<uuid>.<URL scheme>.<host>.<port> — "http" for the loopback.
    private func account(serverID: UUID, harness: Harness) -> String {
        "mcp.\(serverID.uuidString).http.127.0.0.1.\(harness.http.port)"
    }
    private func reference(serverID: UUID, harness: Harness) -> String {
        SecretGatewayNaming.opaqueReference(namespace: "org.floeagent.ios.mcp",
                                            account: account(serverID: serverID,
                                                             harness: harness))
    }

    private func candidate(id: UUID, endpoint: String, auth: String = "bearerToken",
                           enabled: Bool = true, createIntent: Bool = false)
        -> [String: Any] {
        var candidate: [String: Any] = [
            "id": id.uuidString, "displayName": "Test Server",
            "endpoint": endpoint, "enabled": enabled, "allowInsecureHTTP": true,
            "authentication": auth,
        ]
        if createIntent { candidate["createIntent"] = true }
        return candidate
    }

    private func submitIntent(serverID: UUID, candidate: [String: Any], secret: Data,
                              routeToken: String = "route-test") throws -> String {
        let intent: [String: Any] = [
            "intent": "set",
            "subject": ["kind": SubjectKind.mcpSave.rawValue, "id": serverID.uuidString],
            "route": ["token": routeToken, "generation": 7],
            "candidate": candidate,
        ]
        let data = try JSONSerialization.data(withJSONObject: intent, options: [.sortedKeys])
        return try SecretSaveIntentVault.shared.submit(intentJSON: data, secret: secret)
    }

    /// Save a new server through the production Set path.
    private func createServer(_ harness: Harness, auth: String = "bearerToken",
                              enabled: Bool = true,
                              secret: Data = Data("synthetic-secret".utf8)) async throws
        -> UUID {
        let id = UUID()
        let token = try submitIntent(
            serverID: id,
            candidate: candidate(id: id, endpoint: endpoint(harness), auth: auth,
                                 enabled: enabled, createIntent: true),
            secret: secret)
        let reply = await harness.domain.saveSet(ingressToken: token, envelopeRevision: nil)
        if auth != "none" {
            XCTAssertEqual(reply["state"] as? String, "committed",
                           "Set must commit: \(reply)")
        }
        return id
    }

    private func scriptTools(_ harness: Harness, tools: [[String: Any]],
                             delayMillis: Int = 0) {
        let toolsJSON = try! JSONSerialization.data(withJSONObject: tools)
        harness.http.register(path: "/mcp") { connection in
            if delayMillis > 0 { ScriptedLoopbackFixture.sleep(delayMillis) }
            guard let object = try? JSONSerialization.jsonObject(
                with: connection.request.body) as? [String: Any],
                let id = object["id"] as? Int else {
                connection.sendHead(status: 400, headers: ["content-length": "0"])
                return
            }
            let toolsArray = (try? JSONSerialization.jsonObject(with: toolsJSON)) as? [Any] ?? []
            let payload: [String: Any] = [
                "jsonrpc": "2.0", "id": id, "result": ["tools": toolsArray],
            ]
            let data = try! JSONSerialization.data(withJSONObject: payload)
            connection.sendHead(status: 200,
                                headers: ["content-type": "application/json",
                                          "content-length": String(data.count)])
            connection.sendRaw(data)
        }
    }

    private static func completed(_ data: Data) throws -> [String: Any]? {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["state"] as? String, "completed",
                       "expected completed, got \(String(describing: object))")
        return object?["value"] as? [String: Any]
    }
    private static func body(_ data: Data) throws -> [String: Any]? {
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: Set identity + connect registration + wire hygiene

    func testSaveSetCanonicalIdentityThenConnectedTools() async throws {
        let harness = try await makeHarness("set")
        defer { harness.http.stop() }
        scriptTools(harness, tools: [["name": "echo", "description": "echo",
                                      "inputSchema": ["type": "object"]]])
        let id = try await createServer(harness)
        let connectList = try await harness.domain.list(cursor: nil)
        let servers = try XCTUnwrap(connectList["servers"] as? [[String: Any]])
        let row = try XCTUnwrap(servers.first { ($0["id"] as? String) == id.uuidString })
        let connection = try XCTUnwrap(row["connection"] as? [String: Any])
        XCTAssertEqual(connection["state"] as? String, "ready")
        XCTAssertEqual(connection["toolCount"] as? Int, 1)
        // ORIGINAL namespaced registration into the provided registry.
        let prefix = "mcp_" + id.uuidString.replacingOccurrences(of: "-", with: "")
            .lowercased().prefix(10)
        XCTAssertTrue(harness.registry.allDescriptors.map(\.name)
            .contains { $0.hasPrefix(prefix + "_") })
        // Canonical identity: ONE reference, MCP service domain, origin-
        // bound account, exact bytes.
        XCTAssertEqual(harness.gateway.storedReferences(),
                       [reference(serverID: id, harness: harness)])
        XCTAssertEqual(harness.gateway.snapshot(reference: reference(serverID: id,
                                                                     harness: harness)),
                       Data("synthetic-secret".utf8))
        // The list wire never leaks bytes; opaque reference only.
        let rendered = String(decoding: try JSONSerialization.data(
            withJSONObject: connectList["servers"] as Any), as: UTF8.self)
        XCTAssertFalse(rendered.contains("synthetic-secret"))
        XCTAssertTrue(rendered.contains("ref:v1:"))
    }

    // MARK: gateway missing + one-shot lease honesty

    func testSetWithUnregisteredGatewayRefusesAndSpentTokenCannotReplay() async throws {
        let harness = try await makeHarness("nogw", gatewayRegistered: false)
        defer { harness.http.stop() }
        let id = UUID()
        let token = try submitIntent(
            serverID: id,
            candidate: candidate(id: id, endpoint: endpoint(harness), createIntent: true),
            secret: Data("bytes".utf8))
        let first = await harness.domain.saveSet(ingressToken: token, envelopeRevision: nil)
        XCTAssertEqual(first["errorCode"] as? String, "needsConfiguration")
        XCTAssertEqual(first["reason"] as? String, "secretGatewayUnregistered")
        XCTAssertEqual(harness.gateway.counts().writes, 0)
        let replay = await harness.domain.saveSet(ingressToken: token, envelopeRevision: nil)
        XCTAssertEqual(replay["reason"] as? String, "saveIntentAlreadyConsumed")
    }

    // MARK: CV-R4 ambiguous write ⇒ outcomeUnknown, no row claim

    func testAmbiguousWriteOutcomeUnknownNoRowClaim() async throws {
        let harness = try await makeHarness("cvr4")
        defer { harness.http.stop() }
        harness.gateway.failNextWrite = SecretBackendError.dispatcherUnresponsive
        let id = UUID()
        let token = try submitIntent(
            serverID: id,
            candidate: candidate(id: id, endpoint: endpoint(harness), createIntent: true),
            secret: Data("bytes".utf8))
        let reply = await harness.domain.saveSet(ingressToken: token, envelopeRevision: nil)
        XCTAssertEqual(reply["errorCode"] as? String, "runtimeUnavailable")
        XCTAssertTrue(((reply["reason"] as? String) ?? "").hasPrefix("secretOutcomeUnknown"),
                      "claimed dispatcherUnresponsive must be outcomeUnknown (CV-R4)")
        XCTAssertEqual(reply["databaseRowWritten"] as? Bool, false)
        let list = try await harness.domain.list(cursor: nil)
        XCTAssertTrue((try XCTUnwrap(list["servers"] as? [Any])).isEmpty,
                      "no phantom committed row")
        // An UNOBSERVED ambiguous outcome retains its owner/root lease by
        // design until a real restart (the durable intent is the recovery
        // authority). This reset simulates that process boundary so the
        // fixture generation can retire; it is NOT a settlement claim.
        RuntimeOwnedWorkRegistry.shared.removeAllForTesting()
    }

    // MARK: Keep/Clear origin binding

    func testKeepPreservesAndEndpointChangeNeedsSet() async throws {
        let harness = try await makeHarness("keep")
        defer { harness.http.stop() }
        scriptTools(harness, tools: [])
        let id = try await createServer(harness)
        let revisionValue = await harness.domain.currentRevision(serverID: id)
        let revision = try XCTUnwrap(revisionValue)
        let before = harness.gateway.counts()
        let keep = await harness.domain.save(
            candidateJSON: Data(try JSONSerialization.data(
                withJSONObject: candidate(id: id, endpoint: endpoint(harness)),
                options: [.sortedKeys])),
            secretIntent: "keep", envelopeRevision: revision)
        XCTAssertEqual(keep["state"] as? String, "committed")
        XCTAssertEqual(harness.gateway.counts().writes, before.writes,
                       "Keep writes no secret")
        let badKeep = await harness.domain.save(
            candidateJSON: Data(try JSONSerialization.data(
                withJSONObject: candidate(id: id,
                                          endpoint: "http://127.0.0.1:\(harness.http.port)/moved"),
                options: [.sortedKeys])),
            secretIntent: "keep", envelopeRevision: revision)
        XCTAssertEqual(badKeep["reason"] as? String, "mcpKeepConnectionChangedNeedsSet")
        // Clear to .none deletes the bound account via the ledger.
        let clearRevisionValue = await harness.domain.currentRevision(serverID: id)
        let clearRevision = try XCTUnwrap(clearRevisionValue)
        let clear = await harness.domain.save(
            candidateJSON: Data(try JSONSerialization.data(
                withJSONObject: candidate(id: id, endpoint: endpoint(harness), auth: "none"),
                options: [.sortedKeys])),
            secretIntent: "clear",
            envelopeRevision: clearRevision)
        XCTAssertEqual(clear["state"] as? String, "committed")
        XCTAssertNil(harness.gateway.snapshot(reference: reference(serverID: id,
                                                                   harness: harness)),
                     "bound account deleted")
    }

    // MARK: R8 narrow no-secret create (validated .none + explicit Clear)

    /// R8: the advertised Auth=None create path is real — a NEW identity with
    /// validated authentication .none rides the explicit CLEAR intent with
    /// NO secret bytes. The row commits durably and survives readback with
    /// ZERO secret-store reads/writes/deletes and no account binding; the
    /// frozen guards all hold unchanged around the narrow case.
    func testNoneClearCreateCommitsWithoutSecretEffectsAndGuardsHold() async throws {
        let harness = try await makeHarness("nonecreate")
        defer { harness.http.stop() }
        let id = UUID()
        // enabled:false keeps this a pure unit check (no connect hop).
        let create = await harness.domain.save(
            candidateJSON: Data(try JSONSerialization.data(
                withJSONObject: candidate(id: id, endpoint: endpoint(harness),
                                          auth: "none", enabled: false,
                                          createIntent: true),
                options: [.sortedKeys])),
            secretIntent: "clear", envelopeRevision: nil)
        XCTAssertEqual(create["state"] as? String, "committed")
        XCTAssertEqual(create["secretIntent"] as? String, "clear")
        XCTAssertNil(create["secretDisposition"],
                     "a no-secret effect leaves no disposition")
        XCTAssertNil(create["credentialCleanup"],
                     "no account was bound, so nothing is cleaned up")
        // Zero secret-store traffic and no account binding.
        XCTAssertEqual(harness.gateway.counts().writes, 0,
                       "no-secret create writes no secret")
        XCTAssertEqual(harness.gateway.counts().deletes, 0,
                       "no-secret create deletes no secret")
        XCTAssertEqual(harness.gateway.counts().reads, 0,
                       "no-secret create resolves no secret reference")
        XCTAssertTrue(harness.gateway.storedReferences().isEmpty,
                      "no account is ever bound for a none-auth create")
        // Readback: the row is durably listed as none-auth with the honest
        // credential status and a real current revision.
        let list = try await harness.domain.list(cursor: nil)
        let row = try XCTUnwrap((try XCTUnwrap(list["servers"] as? [[String: Any]])
            .first { ($0["id"] as? String) == id.uuidString }))
        XCTAssertEqual(row["authentication"] as? String, "none")
        let credential = try XCTUnwrap(row["credential"] as? [String: Any])
        XCTAssertEqual(credential["required"] as? Bool, false)
        XCTAssertEqual(credential["state"] as? String, "noneConfigured")
        let revisionValue = await harness.domain.currentRevision(serverID: id)
        let revision = try XCTUnwrap(revisionValue)
        // Durability proof: the created row now EXISTS — a follow-up Keep
        // edit is a real edit (committed, still zero secret writes).
        let keep = await harness.domain.save(
            candidateJSON: Data(try JSONSerialization.data(
                withJSONObject: candidate(id: id, endpoint: endpoint(harness),
                                          auth: "none", enabled: false),
                options: [.sortedKeys])),
            secretIntent: "keep", envelopeRevision: revision)
        XCTAssertEqual(keep["state"] as? String, "committed")
        XCTAssertEqual(harness.gateway.counts().writes, 0)
        // Guard 1 (unchanged): a NEW identity still cannot ride Keep…
        let keepNew = await harness.domain.save(
            candidateJSON: Data(try JSONSerialization.data(
                withJSONObject: candidate(id: UUID(), endpoint: endpoint(harness),
                                          auth: "none", enabled: false,
                                          createIntent: true),
                options: [.sortedKeys])),
            secretIntent: "keep", envelopeRevision: nil)
        XCTAssertEqual(keepNew["reason"] as? String, "mcpCreateNeedsSet")
        // Guard 2 (unchanged): an authenticated NEW identity without the
        // frozen Set lease is refused — no auth-bearing anonymous create.
        let authClear = await harness.domain.save(
            candidateJSON: Data(try JSONSerialization.data(
                withJSONObject: candidate(id: UUID(), endpoint: endpoint(harness),
                                          auth: "bearerToken", enabled: false,
                                          createIntent: true),
                options: [.sortedKeys])),
            secretIntent: "clear", envelopeRevision: nil)
        XCTAssertEqual(authClear["reason"] as? String, "mcpCreateNeedsSet")
        // The existing-row create-conflict gate is untouched.
        let conflict = await harness.domain.save(
            candidateJSON: Data(try JSONSerialization.data(
                withJSONObject: candidate(id: id, endpoint: endpoint(harness),
                                          auth: "bearerToken", enabled: false,
                                          createIntent: true),
                options: [.sortedKeys])),
            secretIntent: "clear", envelopeRevision: nil)
        XCTAssertEqual(conflict["reason"] as? String, "mcpCreateConflict")
        // Clear still refuses an auth-bearing candidate on an EXISTING row.
        let existingAuthClear = await harness.domain.save(
            candidateJSON: Data(try JSONSerialization.data(
                withJSONObject: candidate(id: id, endpoint: endpoint(harness),
                                          auth: "bearerToken", enabled: false),
                options: [.sortedKeys])),
            secretIntent: "clear", envelopeRevision: revision)
        XCTAssertEqual(existingAuthClear["reason"] as? String,
                       "mcpClearRequiresNoneAuth")
    }

    // MARK: credential refusal BEFORE dispatch

    func testInvalidCredentialRefusesBeforeAnyRequest() async throws {
        let harness = try await makeHarness("cred")
        defer { harness.http.stop() }
        scriptTools(harness, tools: [])
        let id = try await createServer(harness)
        // Corrupt the stored bytes into invalid UTF-8 (test-side gateway
        // mutation; the canonical reference stays the same).
        await harness.gateway.replaceUnsafe(reference: reference(serverID: id,
                                                                 harness: harness),
                                            with: Data([0xC3, 0x28]))
        let corruptRevisionValue = await harness.domain.currentRevision(serverID: id)
        let corruptRevision = try XCTUnwrap(corruptRevisionValue)
        _ = await harness.domain.disconnect(serverID: id, revision: corruptRevision)
        let requestsBefore = harness.http.count(for: "/mcp")
        let failed = await harness.domain.connect(serverID: id)
        XCTAssertEqual(failed["errorCode"] as? String, "credentialUnavailable")
        XCTAssertEqual(failed["reason"] as? String, "secretInvalidated")
        XCTAssertEqual(harness.http.count(for: "/mcp"), requestsBefore,
                       "typed refusal must precede ANY network dispatch")
    }

    // MARK: disconnect / reconnect / late-discovery fencing

    func testDisconnectThenReconnectRegistersFreshTools() async throws {
        let harness = try await makeHarness("reconnect")
        defer { harness.http.stop() }
        scriptTools(harness, tools: [["name": "one", "description": "d",
                                      "inputSchema": ["type": "object"]]])
        let id = try await createServer(harness)
        XCTAssertFalse(harness.registry.allDescriptors.isEmpty)
        let reconnectRevisionValue = await harness.domain.currentRevision(serverID: id)
        let reconnectRevision = try XCTUnwrap(reconnectRevisionValue)
        _ = await harness.domain.disconnect(serverID: id, revision: reconnectRevision)
        XCTAssertTrue(harness.registry.allDescriptors.isEmpty,
                      "disconnect unregisters the server namespace")
        let again = await harness.domain.connect(serverID: id)
        XCTAssertEqual(again["state"] as? String, "connected")
        XCTAssertFalse(harness.registry.allDescriptors.isEmpty)
    }

    func testCancelRefreshUnderExactGenerationDropsLateResult() async throws {
        let harness = try await makeHarness("cancel")
        defer { harness.http.stop() }
        scriptTools(harness, tools: [["name": "late", "description": "d",
                                      "inputSchema": ["type": "object"]]],
                    delayMillis: 1_500)
        let id = UUID()
        let token = try submitIntent(
            serverID: id,
            candidate: candidate(id: id, endpoint: endpoint(harness), createIntent: true),
            secret: Data("bytes".utf8))
        // enabled:true ⇒ the Set auto-connects; the slow scripted response
        // keeps that connect in-flight for the exact-generation cancel.
        let connectTask = Task {
            _ = await harness.domain.saveSet(ingressToken: token, envelopeRevision: nil)
        }
        var generation = ""
        for _ in 0..<300 {
            let list = try await harness.domain.list(cursor: nil)
            if let servers = list["servers"] as? [[String: Any]],
               let connection = servers.first?["connection"] as? [String: Any],
               connection["state"] as? String == "connecting" {
                generation = (connection["generation"] as? String) ?? ""
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(generation.isEmpty, "connection must be live before cancel")
        let cancel = await harness.domain.cancelRefresh(serverID: id, generation: generation)
        XCTAssertEqual(cancel["state"] as? String, "cancelling")
        _ = await connectTask.value
        // The scripted body finished AFTER cancel; the coordinator's
        // generation+config re-check must have refused registration.
        XCTAssertTrue(harness.registry.allDescriptors.isEmpty,
                      "a cancelled generation's late discovery cannot register")
        let noop = await harness.domain.cancelRefresh(serverID: id, generation: "999999")
        XCTAssertEqual(noop["state"] as? String, "noop")
    }

    // MARK: protocol strictness through the production client

    func testMalformedResponseTyped() async throws {
        let harness = try await makeHarness("malformed")
        defer { harness.http.stop() }
        harness.http.register(path: "/mcp") { connection in
            let data = Data("not json".utf8)
            connection.sendHead(status: 200,
                                headers: ["content-type": "application/json",
                                          "content-length": String(data.count)])
            connection.sendRaw(data)
        }
        let id = try await createServer(harness)
        let failed = await harness.domain.connect(serverID: id)
        XCTAssertNotNil(failed["errorCode"], "malformed responses refuse typed")
        // The server row/config RETAINS state: it is still listed, and the
        // connection state carries the honest failure (retryable).
        let list = try await harness.domain.list(cursor: nil)
        let row = try XCTUnwrap((try XCTUnwrap(list["servers"] as? [[String: Any]])
            .first { ($0["id"] as? String) == id.uuidString }))
        let connection = try XCTUnwrap(row["connection"] as? [String: Any])
        XCTAssertEqual(connection["state"] as? String, "failed")
    }

    func testNoRedirectFollowed() async throws {
        let harness = try await makeHarness("redirect")
        defer { harness.http.stop() }
        harness.http.register(path: "/mcp") { connection in
            connection.sendHead(status: 302,
                                headers: ["location": "http://127.0.0.1:\(harness.http.port)/private"])
        }
        let id = try await createServer(harness)
        let connect = await harness.domain.connect(serverID: id)
        XCTAssertNotNil(connect["errorCode"])
        XCTAssertEqual(harness.http.count(for: "/private"), 0,
                       "MCPNoRedirectSessionDelegate must never follow")
    }

    func testOversizeResponseRefused() async throws {
        let harness = try await makeHarness("oversize")
        defer { harness.http.stop() }
        harness.http.register(path: "/mcp") { connection in
            guard let object = try? JSONSerialization.jsonObject(
                with: connection.request.body) as? [String: Any],
                let id = object["id"] as? Int else {
                connection.sendHead(status: 400, headers: ["content-length": "0"])
                return
            }
            var payload = Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":{\"tools\":[],\"pad\":\""
                .utf8)
            payload.append(Data(repeating: 0x41, count: 2 * 1_024 * 1_024 + 4_096))
            payload.append(Data("\"}}".utf8))
            connection.sendHead(status: 200,
                                headers: ["content-type": "application/json",
                                          "content-length": String(payload.count)])
            connection.sendRaw(payload)
        }
        let id = try await createServer(harness)
        let connect = await harness.domain.connect(serverID: id)
        XCTAssertEqual(connect["errorCode"] as? String, "payloadTooLarge",
                       "responseTooLarge maps onto the frozen payload code")
    }

    func testSSEResponseParsed() async throws {
        let harness = try await makeHarness("sse")
        defer { harness.http.stop() }
        harness.http.register(path: "/mcp") { connection in
            guard let object = try? JSONSerialization.jsonObject(
                with: connection.request.body) as? [String: Any],
                let id = object["id"] as? Int else {
                connection.sendHead(status: 400, headers: ["content-length": "0"])
                return
            }
            let framed = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":\(id),"
                + "\"result\":{\"tools\":[]}}\n\n"
            let data = Data(framed.utf8)
            connection.sendHead(status: 200,
                                headers: ["content-type": "text/event-stream",
                                          "content-length": String(data.count)])
            connection.sendRaw(data)
        }
        let id = try await createServer(harness)
        let connect = await harness.domain.connect(serverID: id)
        XCTAssertEqual(connect["state"] as? String, "connected")
    }

    func testLegacySessionEraFallbackCapturesSession() async throws {
        let harness = try await makeHarness("legacy")
        defer { harness.http.stop() }
        final class AttemptBox: @unchecked Sendable { var listAttempts = 0 }
        let box = AttemptBox()
        harness.http.register(path: "/mcp") { connection in
            guard let object = try? JSONSerialization.jsonObject(
                with: connection.request.body) as? [String: Any] else {
                connection.sendHead(status: 400, headers: ["content-length": "0"])
                return
            }
            let method = object["method"] as? String
            let id = object["id"] as? Int ?? 0
            switch method {
            case "initialize":
                let payload: [String: Any] = [
                    "jsonrpc": "2.0", "id": id,
                    "result": ["protocolVersion": "2025-11-25",
                               "capabilities": [:] as [String: Any],
                               "serverInfo": ["name": "loopback", "version": "1"]],
                ]
                let data = try! JSONSerialization.data(withJSONObject: payload)
                connection.sendHead(status: 200,
                                    headers: ["content-type": "application/json",
                                              "content-length": String(data.count),
                                              "mcp-session-id": "sess-7"])
                connection.sendRaw(data)
            case "notifications/initialized":
                connection.sendHead(status: 202, headers: ["content-length": "0"])
            case "tools/list":
                box.listAttempts += 1
                if box.listAttempts == 1 {
                    // The CURRENT-era attempt: unrecognized empty 404 →
                    // the ORIGINAL shouldFallBackToLegacy path (empty body).
                    connection.sendHead(status: 404, headers: ["content-length": "0"])
                    return
                }
                XCTAssertEqual(connection.request.headers["mcp-session-id"], "sess-7",
                               "legacy era must send the captured session header")
                let payload: [String: Any] = [
                    "jsonrpc": "2.0", "id": id,
                    "result": ["tools": [["name": "legacy.tool", "description": "d",
                                          "inputSchema": ["type": "object"]] as [String: Any]]],
                ]
                let data = try! JSONSerialization.data(withJSONObject: payload)
                connection.sendHead(status: 200,
                                    headers: ["content-type": "application/json",
                                              "content-length": String(data.count)])
                connection.sendRaw(data)
            default:
                connection.sendHead(status: 404, headers: ["content-length": "0"])
            }
        }
        // enabled:true: the Set's auto-connect exercises the legacy era.
        let id = try await createServer(harness)
        let list = try await harness.domain.list(cursor: nil)
        let row = try XCTUnwrap((try XCTUnwrap(list["servers"] as? [[String: Any]])
            .first { ($0["id"] as? String) == id.uuidString }))
        let connection = try XCTUnwrap(row["connection"] as? [String: Any])
        XCTAssertEqual(connection["state"] as? String, "ready")
        XCTAssertEqual(connection["toolCount"] as? Int, 1)
    }

    // MARK: toggles

    func testDisabledServerUnregistersAndKeepConfig() async throws {
        let harness = try await makeHarness("disable")
        defer { harness.http.stop() }
        scriptTools(harness, tools: [["name": "t", "description": "d",
                                      "inputSchema": ["type": "object"]]])
        let id = try await createServer(harness)
        XCTAssertFalse(harness.registry.allDescriptors.isEmpty)
        let disableRevisionValue = await harness.domain.currentRevision(serverID: id)
        let revision = try XCTUnwrap(disableRevisionValue)
        let reply = await harness.domain.setEnabled(serverID: id, enabled: false,
                                                    revision: revision)
        XCTAssertEqual(reply["state"] as? String, "disabled")
        XCTAssertTrue(harness.registry.allDescriptors.isEmpty,
                      "disable unregisters tools (original setEnabled(false))")
        let list = try await harness.domain.list(cursor: nil)
        let row = try XCTUnwrap((try XCTUnwrap(list["servers"] as? [[String: Any]])
            .first { ($0["id"] as? String) == id.uuidString }))
        XCTAssertEqual(row["enabled"] as? Bool, false, "config retained")
    }

    func testToolToggleReRegistersWithoutReconnect() async throws {
        let harness = try await makeHarness("tooltoggle")
        defer { harness.http.stop() }
        scriptTools(harness, tools: [["name": "a", "description": "d",
                                      "inputSchema": ["type": "object"]],
                                     ["name": "b", "description": "d",
                                      "inputSchema": ["type": "object"]]])
        let id = try await createServer(harness)
        let requestsBefore = harness.http.count(for: "/mcp")
        let toggleRevisionValue = await harness.domain.currentRevision(serverID: id)
        let revision = try XCTUnwrap(toggleRevisionValue)
        let reply = await harness.domain.setToolEnabled(serverID: id, remoteName: "b",
                                                        enabled: false, revision: revision)
        XCTAssertEqual(reply["state"] as? String, "applied")
        XCTAssertEqual(harness.http.count(for: "/mcp"), requestsBefore,
                       "per-tool toggle must NOT reconnect (original :474-486)")
        let names = harness.registry.allDescriptors.map(\.name)
        XCTAssertEqual(names.count, 1, "disabled remote tool removed from namespace")
    }

    // MARK: remove ordering

    func testRemoveDeletesThenSettles() async throws {
        let harness = try await makeHarness("remove")
        defer { harness.http.stop() }
        scriptTools(harness, tools: [["name": "echo", "description": "d",
                                      "inputSchema": ["type": "object"]]])
        let id = try await createServer(harness)
        XCTAssertFalse(harness.registry.allDescriptors.isEmpty,
                       "the connected server registered its namespaced tool")
        let removeRevisionValue = await harness.domain.currentRevision(serverID: id)
        let revision = try XCTUnwrap(removeRevisionValue)
        let removed = await harness.domain.remove(serverID: id, revision: revision)
        XCTAssertEqual(removed["state"] as? String, "removed")
        XCTAssertEqual(removed["credentialCleanup"] as? String, "settled")
        XCTAssertNil(harness.gateway.snapshot(reference: reference(serverID: id,
                                                                   harness: harness)))
        XCTAssertTrue(harness.registry.allDescriptors.isEmpty,
                      "remove unregisters the removed server's tools")
        let list = try await harness.domain.list(cursor: nil)
        XCTAssertTrue((try XCTUnwrap(list["servers"] as? [Any])).isEmpty)
    }
}

// MARK: - test-only gateway accessor (production-neutral; the domain's
// own currentRevision helper lives in RuntimeFacadeMCPService.swift)

extension RB6ScriptedGateway {
    func replaceUnsafe(reference: String, with bytes: Data) async {
        try? await write(reference: reference, value: bytes)
    }
}
