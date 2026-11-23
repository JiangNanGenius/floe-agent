// FloeMac MacWorkbenchConnectorParityTests — focused multi-server connector
// tests for the Floe Mac workbench.
//
// SPDX-License-Identifier: MPL-2.0
//
// These tests exercise the REAL service, persistence and transport types
// against a loopback `URLProtocol` fixture: two separately configured
// servers (Bearer + custom header) authenticate on the wire, discover and
// publish their own namespaced tools, an approved call runs end to end, and
// disable/remove/credential rotation behave honestly. No Keychain access,
// no real network, no shared registrations. The tests compile into the same
// module as the workbench sources (the FloeMac test convention); the shared
// modules are imported directly.

import XCTest
import Foundation
#if canImport(FloeMacUnifiedParity)
@testable import FloeMacUnifiedParity
#endif
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import FloeSecurity

// MARK: - Loopback MCP fixture

private struct MCPFixtureRoute: Sendable {
    var expectedAuthorization: String?
    var expectedHeaderName: String?
    var expectedHeaderValue: String?
    var toolNames: [String]
}

private struct MCPFixtureRequest: Sendable {
    var url: String
    var authorization: String?
    var customHeaderValue: String?
}

private final class MCPFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: MCPFixtureRoute] = [:]
    private var requests: [MCPFixtureRequest] = []

    func record(_ request: MCPFixtureRequest) {
        lock.withLock { requests.append(request) }
    }

    func route(for url: String) -> MCPFixtureRoute? {
        lock.withLock { routes[url] }
    }

    func replace(routes newRoutes: [String: MCPFixtureRoute]) {
        lock.withLock {
            routes = newRoutes
            requests = []
        }
    }

    var recordedRequests: [MCPFixtureRequest] {
        lock.withLock { requests }
    }
}

private let mcpFixtureState = MCPFixtureState()

private actor StubScopedGrantPersistenceForConnectors: MacScopedToolGrantPersistence {
    var rows: [StoredGrant] = []

    func allGrants() async throws -> [StoredGrant] { rows }

    func saveGrant(_ grant: StoredGrant) async throws {
        rows.removeAll { $0.id == grant.id }
        rows.append(grant)
    }

    func deleteGrant(id: UUID) async throws {
        rows.removeAll { $0.id == id }
    }
}

private final class MCPFixtureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url?.absoluteString,
              let route = mcpFixtureState.route(for: url),
              let body = Self.body(of: request),
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = object["id"] as? Int,
              let method = object["method"] as? String else {
            respond(status: 400, json: ["error": "bad fixture request"])
            return
        }
        mcpFixtureState.record(.init(
            url: url,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            customHeaderValue: route.expectedHeaderName.flatMap { request.value(forHTTPHeaderField: $0) }
        ))
        // Fail closed without the configured credential, exactly like a
        // real protected MCP endpoint.
        if let expected = route.expectedAuthorization, request.value(forHTTPHeaderField: "Authorization") != expected {
            respond(status: 401, json: ["error": "unauthorized"])
            return
        }
        if let name = route.expectedHeaderName, let value = route.expectedHeaderValue,
           request.value(forHTTPHeaderField: name) != value {
            respond(status: 401, json: ["error": "unauthorized"])
            return
        }
        switch method {
        case "tools/list":
            respond(status: 200, json: [
                "jsonrpc": "2.0", "id": id,
                "result": ["tools": route.toolNames.map { name in
                    ["name": name,
                     "description": "fixture tool \(name)",
                     "inputSchema": ["type": "object", "properties": ["input": ["type": "string"]]]]
                }]
            ])
        case "tools/call":
            respond(status: 200, json: [
                "jsonrpc": "2.0", "id": id,
                "result": ["content": [["type": "text", "text": "Connector receipt verified."]]]
            ])
        default:
            respond(status: 400, json: ["error": "unsupported method"])
        }
    }

    override func stopLoading() {}

    /// URLSession streams upload bodies through `httpBodyStream`; drain it
    /// when `httpBody` is nil.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4096)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func respond(status: Int, json: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - Tests

@MainActor
final class MacWorkbenchConnectorParityTests: XCTestCase {
    private var root: URL!
    private var storeURL: URL!
    private var credentials: MacWorkbenchMemoryCredentialStore!
    private var service: MacWorkbenchConnectorsService!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-connector-parity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        storeURL = root.appendingPathComponent("Connector.json")
        credentials = MacWorkbenchMemoryCredentialStore()
        service = MacWorkbenchConnectorsService(
            store: MacWorkbenchFileConnectorStore(url: storeURL),
            credentials: credentials,
            advertisedToolLimit: 16,
            perServerAdvertisedToolLimit: 8,
            sessionProvider: { _ in
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [MCPFixtureURLProtocol.self]
                return URLSession(configuration: config)
            }
        )
        mcpFixtureState.replace(routes: [:])
    }

    override func tearDown() async throws {
        await service.disconnect()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Migration

    func testLegacySingleServerDocumentMigratesWithoutLoss() async throws {
        let legacy = MacWorkbenchConnectorConfiguration(
            server: MCPServerConfiguration(displayName: "Legacy",
                                           endpoint: URL(string: "http://127.0.0.1/mcp")!,
                                           enabled: false,
                                           allowInsecureHTTP: true))
        try JSONEncoder().encode(legacy).write(to: storeURL, options: .atomic)

        let migrated = try await MacWorkbenchFileConnectorStore(url: storeURL).load()
        XCTAssertEqual(migrated.version, MacWorkbenchConnectorSnapshot.currentVersion)
        XCTAssertEqual(migrated.servers.count, 1)
        XCTAssertEqual(migrated.servers[0].server.displayName, "Legacy")
        XCTAssertEqual(migrated.servers[0].server.endpoint.absoluteString, "http://127.0.0.1/mcp")
        XCTAssertFalse(migrated.servers[0].server.enabled)

        // The file keeps its legacy bytes until the first successful save.
        XCTAssertNotNil(try? JSONDecoder().decode(MacWorkbenchConnectorConfiguration.self,
                                                  from: Data(contentsOf: storeURL)))

        // A successful save writes the snapshot document; the original file
        // path is reused and reloads identically.
        try await MacWorkbenchFileConnectorStore(url: storeURL).save(migrated)
        let reloaded = try await MacWorkbenchFileConnectorStore(url: storeURL).load()
        XCTAssertEqual(reloaded.servers, migrated.servers)
        XCTAssertEqual(reloaded.version, MacWorkbenchConnectorSnapshot.currentVersion)

        // And the service restore surfaces the migrated server.
        await service.restore()
        XCTAssertEqual(service.servers.map(\.displayName), ["Legacy"])
        XCTAssertEqual(service.statusByID[service.servers[0].id], .disabled)
    }

    func testDecodeFailureAndFutureVersionNeverBecomeEmpty() async throws {
        try Data("not json".utf8).write(to: storeURL, options: .atomic)
        do {
            _ = try await MacWorkbenchFileConnectorStore(url: storeURL).load()
            XCTFail("corrupt document must not load as empty")
        } catch {
            XCTAssertEqual(error as? MacWorkbenchConnectorStoreError, .decodeFailed)
        }
        // Saved connectors are untouched: a configure cannot overwrite them.
        XCTAssertEqual(try String(contentsOf: storeURL, encoding: .utf8), "not json")

        let future = MacWorkbenchConnectorSnapshot(version: MacWorkbenchConnectorSnapshot.currentVersion + 1,
                                                   servers: [])
        try JSONEncoder().encode(future).write(to: storeURL, options: .atomic)
        do {
            _ = try await MacWorkbenchFileConnectorStore(url: storeURL).load()
            XCTFail("future version must not load")
        } catch MacWorkbenchConnectorStoreError.unsupportedVersion(let found, _) {
            XCTAssertEqual(found, MacWorkbenchConnectorSnapshot.currentVersion + 1)
        }
    }

    // MARK: Two authenticated servers

    func testTwoServersAuthenticateDiscoverPublishAndRevoke() async throws {
        let endpointA = "http://127.0.0.1/mcp-a"
        let endpointB = "http://127.0.0.1/mcp-b"
        mcpFixtureState.replace(routes: [
            endpointA: .init(expectedAuthorization: "Bearer alpha",
                             toolNames: ["alpha_lookup"]),
            endpointB: .init(expectedHeaderName: "X-Key", expectedHeaderValue: "beta",
                             toolNames: ["beta_receipt", "beta_extra"])
        ])

        let serverA = MCPServerConfiguration(displayName: "Alpha", endpoint: URL(string: endpointA)!,
                                             allowInsecureHTTP: true, authentication: .bearerToken)
        let serverB = MCPServerConfiguration(displayName: "Beta", endpoint: URL(string: endpointB)!,
                                             allowInsecureHTTP: true, authentication: .customHeader,
                                             credentialHeaderName: "X-Key")

        // Missing credential fails honestly at configuration time.
        do {
            try await service.configure(server: serverA)
            XCTFail("bearer server without a credential must not configure")
        } catch MCPClientError.authenticationRequired {
        }

        try await service.configure(server: serverA, credential: "alpha")
        try await service.configure(server: serverB, credential: "beta")
        XCTAssertEqual(service.servers.count, 2)

        // Wrong credential surfaces as an honest failure, not zero tools.
        let wrong = MCPServerConfiguration(
            id: serverA.id, displayName: "Alpha", endpoint: URL(string: endpointA)!,
            allowInsecureHTTP: true, authentication: .bearerToken)
        try await service.configure(server: wrong, credential: "wrong")
        let failedTools = await service.testDiscovery(serverID: serverA.id)
        XCTAssertTrue(failedTools.isEmpty)
        guard case .failed = service.statusByID[serverA.id] else {
            XCTFail("wrong credential must fail discovery"); return
        }

        // Correct credentials: both servers publish their own namespaces.
        try await service.configure(server: serverA, credential: "alpha")
        let toolsA = await service.testDiscovery(serverID: serverA.id)
        let toolsB = await service.testDiscovery(serverID: serverB.id)
        XCTAssertEqual(toolsA.map(\.remoteName), ["alpha_lookup"])
        XCTAssertEqual(toolsB.map(\.remoteName), ["beta_receipt", "beta_extra"])

        XCTAssertEqual(service.publishedTools.count, 3)
        XCTAssertEqual(service.toolOrigins.count, 3)

        // The wire saw each configured credential exactly at its endpoint.
        let seen = mcpFixtureState.recordedRequests
        XCTAssertTrue(seen.contains { $0.url == endpointA && $0.authorization == "Bearer alpha" })
        XCTAssertTrue(seen.contains { $0.url == endpointB && $0.customHeaderValue == "beta" })

        // Namespaces are independent and the origin map names each server.
        let prefixA = serverA.namespacePrefix + "_"
        let prefixB = serverB.namespacePrefix + "_"
        var sawAlpha = false, sawBeta = false
        for tool in service.publishedTools {
            let name = tool.descriptor.name
            XCTAssertTrue(name.hasPrefix(prefixA) || name.hasPrefix(prefixB))
            if let origin = service.toolOrigins[name] {
                if name.hasPrefix(prefixA) {
                    sawAlpha = true
                    XCTAssertEqual(origin.authentication, "bearer")
                    XCTAssertEqual(origin.serverName, "Alpha")
                } else {
                    sawBeta = true
                    XCTAssertEqual(origin.authentication, "customHeader")
                    XCTAssertEqual(origin.serverName, "Beta")
                }
            } else {
                XCTFail("every published tool needs origin metadata")
            }
        }
        XCTAssertTrue(sawAlpha && sawBeta)

        // Binding metadata is exact and endpoint-sensitive.
        let alphaName = service.publishedTools.first { $0.descriptor.name.hasPrefix(prefixA) }!.descriptor.name
        let bindingA = service.binding(for: alphaName)
        XCTAssertNotNil(bindingA)
        XCTAssertEqual(bindingA?.host, "127.0.0.1")
        XCTAssertNotEqual(MacWorkbenchConnectorsService.endpointDigest(URL(string: endpointA)!),
                          MacWorkbenchConnectorsService.endpointDigest(URL(string: endpointB)!))
        XCTAssertEqual(bindingA?.endpointDigest,
                       MacWorkbenchConnectorsService.endpointDigest(URL(string: endpointA)!))

        // Permission → actual synthetic call through the published tool.
        let alphaTool = service.publishedTools.first { $0.descriptor.name.hasPrefix(prefixA) }!
        let context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        let output = try await alphaTool.run(Data(#"{"input":"x"}"#.utf8), context)
        XCTAssertTrue(output.summary.contains("Connector receipt verified."))

        // Disable revokes publication but keeps the persisted record.
        try await service.setEnabled(false, serverID: serverA.id)
        XCTAssertTrue(service.publishedTools.allSatisfy { !$0.descriptor.name.hasPrefix(prefixA) })
        XCTAssertEqual(service.servers.first { $0.id == serverA.id }?.enabled, false)
        let credentialKept = try await credentials.hasCredential(for: serverA)
        XCTAssertTrue(credentialKept)

        // Re-enable rediscovers and republishes.
        try await service.setEnabled(true, serverID: serverA.id)
        XCTAssertEqual(service.publishedTools.count, 3)

        // Remove tears down publication and deletes the credential.
        try await service.remove(serverID: serverA.id)
        XCTAssertEqual(service.servers.count, 1)
        XCTAssertFalse(service.toolOrigins.values.contains { $0.serverID == serverA.id })
        let credentialDeleted = try await credentials.hasCredential(for: serverA)
        XCTAssertFalse(credentialDeleted)
    }

    // MARK: Credential rebinding

    func testCredentialRebindsToOriginAndAuthChanges() async throws {
        let endpoint = "http://127.0.0.1/mcp-a"
        mcpFixtureState.replace(routes: [endpoint: .init(expectedAuthorization: "Bearer one",
                                                  toolNames: ["tool"])])
        let server = MCPServerConfiguration(displayName: "Alpha", endpoint: URL(string: endpoint)!,
                                            allowInsecureHTTP: true, authentication: .bearerToken)
        try await service.configure(server: server, credential: "one")

        // Same identity + origin + auth keeps the credential across edits.
        var edited = server
        edited.displayName = "Alpha renamed"
        try await service.configure(server: edited)
        let credentialSurvivedEdit = try await credentials.hasCredential(for: edited)
        XCTAssertTrue(credentialSurvivedEdit)

        // An origin change requires re-authorization and keeps the old item
        // bound to the old destination. (A same-origin path edit reuses the
        // credential by design, mirroring the iPad binding.)
        let moved = MCPServerConfiguration(id: server.id, displayName: "Alpha",
                                           endpoint: URL(string: "http://127.0.0.1:8080/mcp")!,
                                           allowInsecureHTTP: true, authentication: .bearerToken)
        do {
            try await service.configure(server: moved)
            XCTFail("moved endpoint without a new credential must fail")
        } catch MCPClientError.authenticationRequired {
        }
        let originalKept = try await credentials.hasCredential(for: server)
        let movedAbsent = try await credentials.hasCredential(for: moved)
        XCTAssertTrue(originalKept)
        XCTAssertFalse(movedAbsent)

        // An auth-method change likewise requires re-authorization and the
        // keychain account binding differs.
        let headerAuth = MCPServerConfiguration(id: server.id, displayName: "Alpha",
                                                endpoint: URL(string: endpoint)!,
                                                allowInsecureHTTP: true,
                                                authentication: .customHeader,
                                                credentialHeaderName: "X-Key")
        XCTAssertNotEqual(MacWorkbenchKeychainCredentialStore.account(for: server),
                          MacWorkbenchKeychainCredentialStore.account(for: headerAuth))
        do {
            try await service.configure(server: headerAuth)
            XCTFail("auth change without a new credential must fail")
        } catch MCPClientError.authenticationRequired {
        }
    }

    // MARK: Scoped grant revocation on lifecycle

    func testDisableAndRemoveRevokeScopedGrantsInServerNamespace() async throws {
        let endpoint = "http://127.0.0.1/mcp-revoke"
        mcpFixtureState.replace(routes: [endpoint: .init(toolNames: ["revoke_tool"])])
        let store = StubScopedGrantPersistenceForConnectors()
        await MacScopedToolGrants.shared.setPersistenceForParityTests(store)
        defer { Task { await MacScopedToolGrants.shared.setPersistenceForParityTests(nil) } }
        let server = MCPServerConfiguration(displayName: "Revoke", endpoint: URL(string: endpoint)!,
                                            allowInsecureHTTP: true)
        try await service.configure(server: server)
        let tools = await service.testDiscovery(serverID: server.id)
        XCTAssertEqual(tools.count, 1)
        let localName = service.publishedTools[0].descriptor.name
        let binding = service.binding(for: localName)!

        // Persisted grants from BEFORE any discovery (previous launch) and
        // after discovery both live in the same server namespace.
        let argsDigest = MacWorkbenchConnectorToolBinding.argumentsDigest(Data("{}".utf8))
        try await MacScopedToolGrants.shared.remember(
            scope: .task, workspaceID: UUID(), conversationID: UUID(), toolName: localName,
            descriptorIdentity: binding.descriptorIdentity, endpointDigest: binding.endpointDigest,
            authenticationDigest: binding.authenticationDigest, argumentsDigest: argsDigest)
        let staleName = server.namespacePrefix + "_stale_01234567"
        try await MacScopedToolGrants.shared.remember(
            scope: .project, workspaceID: UUID(), conversationID: UUID(), toolName: staleName,
            descriptorIdentity: "old-identity", endpointDigest: binding.endpointDigest,
            authenticationDigest: binding.authenticationDigest, argumentsDigest: argsDigest)
        let seededCount = try await MacScopedToolGrants.shared.list().count
        XCTAssertEqual(seededCount, 2)

        // Disabling revokes the whole server namespace.
        try await service.setEnabled(false, serverID: server.id)
        let afterDisable = try await MacScopedToolGrants.shared.list()
        XCTAssertTrue(afterDisable.isEmpty)

        // Removing a never-connected server still clears its credential.
        let lonely = MCPServerConfiguration(displayName: "Lonely",
                                            endpoint: URL(string: "http://127.0.0.1:8081/mcp")!,
                                            allowInsecureHTTP: true, authentication: .bearerToken)
        try await service.configure(server: lonely, credential: "secret")
        // Never discovered: no live registration, but the credential exists.
        let lonelyCredentialStored = try await credentials.hasCredential(for: lonely)
        XCTAssertTrue(lonelyCredentialStored)
        try await service.remove(serverID: lonely.id)
        let lonelyCredential = try await credentials.hasCredential(for: lonely)
        XCTAssertFalse(lonelyCredential)
        let revokeNamespaceCleared = try await MacScopedToolGrants.shared.list().isEmpty
        XCTAssertTrue(revokeNamespaceCleared)
    }

    // MARK: Bounded advertised selection

    func testAdvertisedSelectionIsBoundedAndStable() async throws {
        let endpoint = "http://127.0.0.1/mcp-many"
        let toolNames = (0..<40).map { "bulk_\($0)" }
        mcpFixtureState.replace(routes: [endpoint: .init(toolNames: toolNames)])
        let server = MCPServerConfiguration(displayName: "Bulk", endpoint: URL(string: endpoint)!,
                                            allowInsecureHTTP: true)
        try await service.configure(server: server)
        let tools = await service.testDiscovery(serverID: server.id)
        XCTAssertEqual(tools.count, 40)
        XCTAssertEqual(service.publishedTools.count, 8) // per-server cap
        let firstPass = service.publishedTools.map(\.descriptor.name)
        await service.testDiscovery(serverID: server.id)
        XCTAssertEqual(service.publishedTools.map(\.descriptor.name), firstPass)

        // Disabling some tools lets the next ones in, deterministically.
        var edited = server
        edited.disabledRemoteToolNames = Set(["bulk_0", "bulk_1"])
        try await service.configure(server: edited)
        func advertisedBase(_ name: String) -> String {
            String(name.dropFirst(server.namespacePrefix.count + 1))
        }
        let advertised = service.publishedTools.map { advertisedBase($0.descriptor.name) }
        XCTAssertEqual(advertised.count, 8)
        XCTAssertFalse(advertised.contains { $0.hasPrefix("bulk_0") })
        XCTAssertFalse(advertised.contains { $0.hasPrefix("bulk_1") })
    }
}
