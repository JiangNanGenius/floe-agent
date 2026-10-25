import Foundation
import Testing
import FloeExecution
@testable import FloeTools

private final class MCPStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        var status: Int
        var headers: [String: String]
        var body: Data
        var delay: TimeInterval = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [Stub] = []
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func prepare(_ values: [Stub]) {
        lock.lock()
        stubs = values
        requests = []
        lock.unlock()
    }

    static func capturedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub: Stub? = Self.lock.withLock {
            var captured = request
            if captured.httpBody == nil, let stream = captured.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var body = Data()
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(buffer, count: count)
                }
                captured.httpBody = body
            }
            Self.requests.append(captured)
            return Self.stubs.isEmpty ? nil : Self.stubs.removeFirst()
        }
        guard let stub,
              let response = HTTPURLResponse(
                url: request.url!, statusCode: stub.status,
                httpVersion: "HTTP/1.1", headerFields: stub.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: MCPClientError.invalidResponse("missing test stub"))
            return
        }
        let deliver = {
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !stub.body.isEmpty { self.client?.urlProtocol(self, didLoad: stub.body) }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if stub.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + stub.delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {}
}

@Suite("FloeTools.MCPRemoteToolSource", .serialized)
struct MCPRemoteToolSourceTests {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MCPStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test("Canvas policy exposes bounded native and scoped Notes tools unless MCP is explicitly granted")
    func canvasPolicyDefaultsClosed() {
        let server = MCPServerConfiguration(
            displayName: "Assets",
            endpoint: URL(string: "https://mcp.example.test/api")!
        )
        let tool = MCPDiscoveredTool(
            remoteName: "asset.search",
            displayName: nil,
            toolDescription: "Search assets",
            inputSchemaJSON: #"{"type":"object"}"#,
            readOnlyHint: true,
            destructiveHint: false
        )

        let names = CanvasAgentToolPolicy.allowedToolNames(
            servers: [server],
            discoveredTools: [server.id: [tool]]
        )

        #expect(names == CanvasAgentToolPolicy.nativeToolNames)
        #expect(names == [
            "web.search", "web.fetch",
            "canvas.getState", "canvas.applyOperations", "canvas.delete",
            "canvas.assetSearch", "canvas.assetInsert", "canvas.assetImport",
            "canvas.generate", "canvas.generationStatus",
            "canvas.designGetState", "canvas.designCapabilities",
            "canvas.designCreate", "canvas.designUpdateBrief", "canvas.designUpdateSpec",
            "canvas.designRegisterRevision", "canvas.designAddFeedback",
            "canvas.designPropose", "canvas.designAdopt", "canvas.designReject",
            "canvas.designRestore",
            // Bounded canvas→ordinary-task handoff (already in nativeToolNames
            // since the accepted handoff round; the explicit list was stale).
            "canvas.startOrdinaryTask",
            "notes.read", "notes.search", "notes.edit", "notes.attachFile", "notes.export",
            "video.models",
            "image.models",
        ])
        // Read-only discovery catalogs only: no image/video generation or
        // editing tools enter the canvas ceiling through them.
        #expect(!names.contains("image.generate"))
        #expect(!names.contains("image.process"))
        #expect(!names.contains("canvas.inspect"))
        #expect(!names.contains("canvas.applyPatch"))
        #expect(!names.contains("web.searchAI"))
        #expect(!names.contains(where: { $0.hasPrefix("browser.") }))
    }

    @Test("Canvas policy includes only enabled tools from an explicitly granted MCP server")
    func canvasPolicyFiltersMCPTools() {
        let allowed = MCPServerConfiguration(
            displayName: "Assets",
            endpoint: URL(string: "https://mcp.example.test/api")!,
            allowInCanvas: true,
            disabledRemoteToolNames: ["asset.delete"]
        )
        let tools = [
            MCPDiscoveredTool(
                remoteName: "asset.search", displayName: nil,
                toolDescription: "Search assets", inputSchemaJSON: #"{"type":"object"}"#,
                readOnlyHint: true, destructiveHint: false
            ),
            MCPDiscoveredTool(
                remoteName: "asset.delete", displayName: nil,
                toolDescription: "Delete assets", inputSchemaJSON: #"{"type":"object"}"#,
                readOnlyHint: false, destructiveHint: true
            )
        ]
        var disabled = allowed
        disabled.id = UUID()
        disabled.enabled = false

        let names = CanvasAgentToolPolicy.allowedToolNames(
            servers: [allowed, disabled],
            discoveredTools: [allowed.id: tools, disabled.id: tools]
        )
        let expected = MCPRemoteToolSource.namespacedName(
            prefix: allowed.namespacePrefix + "_",
            remoteName: "asset.search"
        )
        let rejected = MCPRemoteToolSource.namespacedName(
            prefix: allowed.namespacePrefix + "_",
            remoteName: "asset.delete"
        )

        #expect(names == CanvasAgentToolPolicy.nativeToolNames.union([expected]))
        #expect(!names.contains(rejected))
    }

    @Test("Credential-bearing MCP requests never follow redirects")
    func rejectsRedirects() throws {
        let delegate = MCPNoRedirectSessionDelegate()
        let originalURL = try #require(URL(string: "https://mcp.example.test/api"))
        let redirectedURL = try #require(URL(string: "https://redirect.example.test/capture"))
        let task = URLSession.shared.dataTask(with: originalURL)
        let response = try #require(HTTPURLResponse(
            url: originalURL,
            statusCode: 307,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": redirectedURL.absoluteString]
        ))
        var completionWasCalled = false
        var followedRequest: URLRequest? = URLRequest(url: redirectedURL)

        delegate.urlSession(
            URLSession.shared,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: redirectedURL)
        ) { request in
            completionWasCalled = true
            followedRequest = request
        }

        #expect(completionWasCalled)
        #expect(followedRequest == nil)
    }

    @Test("HTTP endpoints require an explicit trusted-LAN override")
    func validatesTransportSecurity() throws {
        let insecure = MCPServerConfiguration(
            displayName: "LAN", endpoint: URL(string: "http://192.168.1.8/mcp")!
        )
        #expect(throws: (any Error).self) { try insecure.validate() }

        var allowed = insecure
        allowed.allowInsecureHTTP = true
        try allowed.validate()

        let embeddedCredential = MCPServerConfiguration(
            displayName: "Bad", endpoint: URL(string: "https://user:secret@example.test/mcp")!
        )
        #expect(throws: (any Error).self) { try embeddedCredential.validate() }

        let protectedHeader = MCPServerConfiguration(
            displayName: "Bad Header",
            endpoint: URL(string: "https://example.test/mcp")!,
            authentication: .customHeader,
            credentialHeaderName: "Mcp-Method"
        )
        #expect(throws: (any Error).self) { try protectedHeader.validate() }
    }

    @Test("Current Streamable HTTP sends per-request metadata and routing headers")
    func discoversToolsWithCurrentProtocol() async throws {
        MCPStubURLProtocol.prepare([
            .init(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","tools":[{"name":"read-note","description":"Read a note","inputSchema":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"additionalProperties":false},"annotations":{"readOnlyHint":true}}]}}"#.utf8)
            )
        ])
        let config = MCPServerConfiguration(
            displayName: "Notes", endpoint: URL(string: "https://mcp.example.test/api")!
        )
        let client = try MCPRemoteClient(configuration: config, credential: nil, session: session())
        let tools = try await client.discoverTools()

        #expect(tools.map(\.remoteName) == ["read-note"])
        #expect(tools.first?.readOnlyHint == true)
        #expect(tools.first?.inputSchemaJSON.contains(#""required":["id"]"#) == true)
        let requests = MCPStubURLProtocol.capturedRequests()
        #expect(requests.count == 1)
        #expect(requests[0].value(forHTTPHeaderField: "MCP-Protocol-Version") == "2026-07-28")
        #expect(requests[0].value(forHTTPHeaderField: "Mcp-Method") == "tools/list")
        #expect(requests[0].value(forHTTPHeaderField: "Mcp-Session-Id") == nil)
        let body = try #require(requests[0].httpBody)
        let envelope = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let params = try #require(envelope["params"] as? [String: Any])
        let metadata = try #require(params["_meta"] as? [String: Any])
        #expect(metadata["io.modelcontextprotocol/protocolVersion"] as? String == "2026-07-28")
    }

    @Test("Legacy servers fall back to initialize and preserve the session header")
    func fallsBackToLegacySessionProtocol() async throws {
        MCPStubURLProtocol.prepare([
            .init(status: 400, headers: [:], body: Data("legacy endpoint".utf8)),
            .init(
                status: 200,
                headers: ["Content-Type": "application/json", "Mcp-Session-Id": "session-1"],
                body: Data(#"{"jsonrpc":"2.0","id":2,"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"test","version":"1"}}}"#.utf8)
            ),
            .init(status: 202, headers: [:], body: Data()),
            .init(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"jsonrpc":"2.0","id":3,"result":{"tools":[]}}"#.utf8)
            )
        ])
        let config = MCPServerConfiguration(
            displayName: "Legacy", endpoint: URL(string: "https://legacy.example.test/mcp")!
        )
        let client = try MCPRemoteClient(configuration: config, credential: nil, session: session())
        #expect(try await client.discoverTools().isEmpty)

        let requests = MCPStubURLProtocol.capturedRequests()
        #expect(requests.count == 4)
        #expect(requests[0].value(forHTTPHeaderField: "Mcp-Method") == "tools/list")
        #expect(requests[1].value(forHTTPHeaderField: "MCP-Protocol-Version") == "2025-11-25")
        #expect(requests[2].value(forHTTPHeaderField: "Mcp-Session-Id") == "session-1")
        #expect(requests[3].value(forHTTPHeaderField: "Mcp-Session-Id") == "session-1")
    }

    @Test("Tool calls mirror validated x-mcp-header parameters and encode non-ASCII")
    func mirrorsToolParametersIntoHeaders() async throws {
        MCPStubURLProtocol.prepare([
            .init(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","tools":[{"name":"search","description":"Search","inputSchema":{"type":"object","properties":{"region":{"type":"string","x-mcp-header":"Region"},"options":{"type":"object","properties":{"safe":{"type":"boolean","x-mcp-header":"Safe"}}}}}}]}}"#.utf8)
            ),
            .init(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"jsonrpc":"2.0","id":2,"result":{"resultType":"complete","content":[{"type":"text","text":"ok"}],"isError":false}}"#.utf8)
            )
        ])
        let config = MCPServerConfiguration(
            displayName: "Search", endpoint: URL(string: "https://search.example.test/mcp")!
        )
        let client = try MCPRemoteClient(configuration: config, credential: nil, session: session())
        _ = try await client.discoverTools()
        let output = try await client.callTool(
            name: "search",
            argumentsJSON: Data(#"{"region":"澳洲","options":{"safe":true}}"#.utf8)
        )
        #expect(output.summary == "ok")

        let request = try #require(MCPStubURLProtocol.capturedRequests().last)
        #expect(request.value(forHTTPHeaderField: "Mcp-Method") == "tools/call")
        #expect(request.value(forHTTPHeaderField: "Mcp-Name") == "search")
        #expect(request.value(forHTTPHeaderField: "Mcp-Param-Region") == "=?base64?5r6z5rSy?=")
        #expect(request.value(forHTTPHeaderField: "Mcp-Param-Safe") == "true")
    }

    @Test("Malformed x-mcp-header tools are excluded without hiding valid siblings")
    func excludesMalformedMirroredHeaders() async throws {
        MCPStubURLProtocol.prepare([
            .init(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"bad","inputSchema":{"type":"object","properties":{"value":{"type":"number","x-mcp-header":"Value"}}}},{"name":"good","inputSchema":{"type":"object","additionalProperties":false}}]}}"#.utf8)
            )
        ])
        let config = MCPServerConfiguration(
            displayName: "Mixed", endpoint: URL(string: "https://mixed.example.test/mcp")!
        )
        let client = try MCPRemoteClient(configuration: config, credential: nil, session: session())
        #expect(try await client.discoverTools().map(\.remoteName) == ["good"])
    }

    @Test("Mirrored header values are bounded before a network request")
    func boundsMirroredHeaderValues() async throws {
        MCPStubURLProtocol.prepare([
            .init(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"search","inputSchema":{"type":"object","properties":{"query":{"type":"string","x-mcp-header":"Query"}}}}]}}"#.utf8)
            )
        ])
        let config = MCPServerConfiguration(
            displayName: "Bounded", endpoint: URL(string: "https://bounded.example.test/mcp")!
        )
        let client = try MCPRemoteClient(configuration: config, credential: nil, session: session())
        _ = try await client.discoverTools()

        let oversized = String(repeating: "x", count: MCPRemoteClient.maximumMirroredHeaderValueBytes + 1)
        let arguments = try JSONSerialization.data(withJSONObject: ["query": oversized])
        await #expect(throws: (any Error).self) {
            try await client.callTool(name: "search", argumentsJSON: arguments)
        }
        #expect(MCPStubURLProtocol.capturedRequests().count == 1)
    }

    @Test("Discovery rejects repeated pagination cursors")
    func rejectsRepeatedPaginationCursor() async throws {
        let page = Data(#"{"jsonrpc":"2.0","id":1,"result":{"tools":[],"nextCursor":"same"}}"#.utf8)
        MCPStubURLProtocol.prepare([
            .init(status: 200, headers: ["Content-Type": "application/json"], body: page),
            .init(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"jsonrpc":"2.0","id":2,"result":{"tools":[],"nextCursor":"same"}}"#.utf8)
            )
        ])
        let config = MCPServerConfiguration(
            displayName: "Paged", endpoint: URL(string: "https://paged.example.test/mcp")!
        )
        let client = try MCPRemoteClient(configuration: config, credential: nil, session: session())
        await #expect(throws: (any Error).self) { try await client.discoverTools() }
        #expect(MCPStubURLProtocol.capturedRequests().count == 2)
    }

    @Test("Dynamic MCP runners enforce the advertised argument schema")
    func validatesDynamicArguments() async throws {
        MCPStubURLProtocol.prepare([])
        let registry = ToolRunnerRegistry()
        let config = MCPServerConfiguration(
            displayName: "Strict", endpoint: URL(string: "https://strict.example.test/mcp")!
        )
        let client = try MCPRemoteClient(configuration: config, credential: nil, session: session())
        MCPRemoteToolSource.register(
            configuration: config,
            client: client,
            tools: [MCPDiscoveredTool(
                remoteName: "lookup", displayName: nil, toolDescription: "Lookup",
                inputSchemaJSON: #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"additionalProperties":false}"#,
                readOnlyHint: true, destructiveHint: false
            )],
            registry: registry
        )
        let registeredName = try #require(registry.allDescriptors.first?.name)
        let runner = try #require(registry.runner(named: registeredName))
        let context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        await #expect(throws: (any Error).self) {
            try await runner.execute(argumentsJSON: Data(#"{"id":7}"#.utf8), context: context)
        }
        await #expect(throws: (any Error).self) {
            try await runner.execute(argumentsJSON: Data(#"{"id":"ok","hidden":true}"#.utf8), context: context)
        }
        #expect(MCPStubURLProtocol.capturedRequests().isEmpty)
    }

    @Test("Dynamic names are provider-safe and server removal is bounded")
    func registersNamespacedTools() throws {
        let registry = ToolRunnerRegistry()
        let config = MCPServerConfiguration(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            displayName: "Example", endpoint: URL(string: "https://example.test/mcp")!
        )
        let client = try MCPRemoteClient(configuration: config, credential: nil, session: session())
        MCPRemoteToolSource.register(
            configuration: config,
            client: client,
            tools: [MCPDiscoveredTool(
                remoteName: "read.note/value", displayName: nil,
                toolDescription: "Read", inputSchemaJSON: #"{"type":"object"}"#,
                readOnlyHint: true, destructiveHint: false
            )],
            registry: registry
        )
        let descriptor = try #require(registry.allDescriptors.first)
        #expect(descriptor.name.hasPrefix("mcp_aaaaaaaabb_read_note_value_"))
        #expect(descriptor.name.count <= 64)
        #expect(descriptor.effect == .mutating)
        #expect(descriptor.isSideEffecting)
        #expect(descriptor.riskLabels == [.networkAccess, .modifiesRemoteSystem])

        MCPRemoteToolSource.unregister(configuration: config, registry: registry)
        #expect(registry.allDescriptors.isEmpty)
    }

    private func dataProConfiguration(id: UUID = UUID()) -> MCPServerConfiguration {
        MCPServerConfiguration(
            id: id, displayName: VolcengineProfessionalSearch.displayName,
            endpoint: VolcengineProfessionalSearch.endpoint,
            authentication: .customHeader,
            credentialHeaderName: VolcengineProfessionalSearch.credentialHeaderName
        )
    }

    private var dataProTool: MCPDiscoveredTool {
        MCPDiscoveredTool(
            remoteName: "dataPro_search", displayName: "Professional data",
            toolDescription: "Search datasets", inputSchemaJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}"#,
            readOnlyHint: true, destructiveHint: false
        )
    }

    @Test("One native web.search routes the exact DataPro query; no professional alias exists")
    func professionalSearchRoutesExactQueryAndPreservesAuthority() async throws {
        MCPStubURLProtocol.prepare([
            .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"synthetic company dataset result"}]}}"#.utf8)),
            .init(status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"synthetic unified dataset result"}]}}"#.utf8))
        ])
        let config = dataProConfiguration()
        let client = try MCPRemoteClient(configuration: config, credential: "synthetic-test-credential", session: session())
        let registry = ToolRunnerRegistry()
        MCPRemoteToolSource.register(configuration: config, client: client, tools: [dataProTool], registry: registry)
        let legacyName = VolcengineProfessionalSearch.toolName(for: config)
        let rawName = MCPRemoteToolSource.namespacedName(prefix: config.namespacePrefix + "_", remoteName: "dataPro_search")
        let raw = try #require(registry.runner(named: rawName))
        // The raw generic MCP runner keeps its original conservative approval
        // classification. Neither it nor a professional facade is discoverable.
        #expect(registry.allDescriptors.isEmpty)
        #expect(registry.runner(named: legacyName) == nil)
        #expect(raw.descriptor.effect == .mutating)
        #expect(raw.descriptor.isSideEffecting)
        #expect(raw.descriptor.riskLabels == [.networkAccess, .modifiesRemoteSystem])
        #expect(!TemporaryChatToolPolicy.isReadOnlySafe(raw.descriptor))
        #expect(!ChatToolPolicy.isAllowedName(legacyName))
        let account = try #require(VolcengineProfessionalSearch.registeredInstances(
            registry: registry
        ).first { $0.serverID == config.id })
        #expect(account.displayName == VolcengineProfessionalSearch.displayName)

        // Direct raw transport remains the generic MCP path (canonical runtime
        // approval is tested elsewhere); this is not the native-query route.
        let query = "企业工商：查询腾讯和阿里巴巴的公司档案。"
        let rawOutput = try await raw.execute(
            argumentsJSON: try JSONSerialization.data(withJSONObject: ["query": query]),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(rawOutput.summary.contains("synthetic company dataset result"))

        let tool = WebSearchTool(
            service: WebSearchService(),
            professional: MCPRegistryProfessionalSearchExecutor(registry: registry)
        )
        registry.register(tool)
        #expect(registry.allDescriptors.map(\.name) == [WebSearchTool.name])
        #expect(registry.allDescriptors[0].effect == .readOnly)
        #expect(registry.allDescriptors[0].riskLabels == [.networkAccess])
        let authority = ProfessionalSearchAuthority.freeze(
            registry: registry,
            allowedToolNames: [WebSearchTool.name]
        )
        let unifiedContext = ToolContext(
            runID: UUID(),
            allowedToolNames: [WebSearchTool.name],
            professionalSearchAuthority: authority,
            cancellation: CancellationToken(),
            frozenEffectiveCatalogNames: [WebSearchTool.name]
        )
        let unifiedArguments = try JSONDecoder().decode(
            WebSearchTool.Arguments.self,
            from: Data(#"{"query":"司法案例：车辆贬值损失 裁判观点","source":"professional"}"#.utf8)
        )
        let unifiedOutput = try await tool.execute(unifiedArguments, context: unifiedContext)
        let unifiedRequest = try #require(MCPStubURLProtocol.capturedRequests().last)
        let unifiedBody = try #require(unifiedRequest.httpBody)
        let unifiedEnvelope = try #require(JSONSerialization.jsonObject(with: unifiedBody) as? [String: Any])
        let unifiedParams = try #require(unifiedEnvelope["params"] as? [String: Any])
        #expect(unifiedParams["name"] as? String == "dataPro_search")
        #expect((unifiedParams["arguments"] as? [String: String])
            == ["query": "司法案例：车辆贬值损失 裁判观点"])
        let unifiedResult = try #require(
            JSONSerialization.jsonObject(with: Data(unifiedOutput.summary.utf8)) as? [String: Any]
        )
        #expect(unifiedResult["contentState"] as? String == "professionalDatasetSummary")
        #expect(unifiedResult["serverID"] as? String == config.id.uuidString)
        #expect(unifiedResult["content"] as? String == "synthetic unified dataset result")

        MCPRemoteToolSource.unregister(configuration: config, registry: registry)
        #expect(registry.allDescriptors.map(\.name) == [WebSearchTool.name])
        #expect(registry.runner(named: rawName) == nil)
        #expect(registry.runner(named: legacyName) == nil)
        #expect(!VolcengineProfessionalSearch.registeredInstances(
            registry: registry
        ).contains { $0.serverID == config.id })
    }

    @Test("DataPro organization is exact, enabled, per-account and does not promote arbitrary MCP methods")
    func professionalSearchRequiresExactLocalIdentityAndReadiness() throws {
        let registry = ToolRunnerRegistry()
        let first = dataProConfiguration(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
        let second = dataProConfiguration(id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-FFFFFFFFFFFF")!)
        for config in [first, second] {
            let client = try MCPRemoteClient(configuration: config, credential: "synthetic-test-credential", session: session())
            MCPRemoteToolSource.register(configuration: config, client: client, tools: [dataProTool], registry: registry)
        }
        #expect(VolcengineProfessionalSearch.toolName(for: first) != VolcengineProfessionalSearch.toolName(for: second))
        #expect(VolcengineProfessionalSearch.toolName(for: first).count <= 64)
        #expect(registry.runner(named: VolcengineProfessionalSearch.toolName(for: first)) == nil)
        #expect(registry.runner(named: VolcengineProfessionalSearch.toolName(for: second)) == nil)
        let ledgerIDs = Set(VolcengineProfessionalSearch.registeredInstances(registry: registry).map(\.serverID))
        #expect(ledgerIDs.contains(first.id))
        #expect(ledgerIDs.contains(second.id))
        MCPRemoteToolSource.unregister(configuration: first, registry: registry)
        #expect(registry.runner(named: VolcengineProfessionalSearch.toolName(for: first)) == nil)
        #expect(registry.runner(named: VolcengineProfessionalSearch.toolName(for: second)) == nil)
        #expect(!VolcengineProfessionalSearch.registeredInstances(registry: registry).contains { $0.serverID == first.id })
        #expect(VolcengineProfessionalSearch.registeredInstances(registry: registry).contains { $0.serverID == second.id })
        MCPRemoteToolSource.unregister(configuration: second, registry: registry)

        var foreign = dataProConfiguration()
        foreign.endpoint = URL(string: "https://unrelated.example.test/mcp")!
        var disabled = dataProConfiguration()
        disabled.enabled = false
        var disabledTool = dataProConfiguration()
        disabledTool.disabledRemoteToolNames = ["dataPro_search"]
        for config in [foreign, disabled, disabledTool] {
            let client = try MCPRemoteClient(configuration: config, credential: "synthetic-test-credential", session: session())
            MCPRemoteToolSource.register(configuration: config, client: client, tools: [dataProTool], registry: registry)
            #expect(registry.runner(named: VolcengineProfessionalSearch.toolName(for: config)) == nil)
            #expect(!VolcengineProfessionalSearch.registeredInstances(registry: registry).contains { $0.serverID == config.id })
            MCPRemoteToolSource.unregister(configuration: config, registry: registry)
        }
        let exact = dataProConfiguration()
        let client = try MCPRemoteClient(configuration: exact, credential: "synthetic-test-credential", session: session())
        var arbitrary = dataProTool
        arbitrary.remoteName = "company.delete"
        MCPRemoteToolSource.register(configuration: exact, client: client, tools: [arbitrary], registry: registry)
        #expect(registry.runner(named: VolcengineProfessionalSearch.toolName(for: exact)) == nil)
        #expect(!VolcengineProfessionalSearch.registeredInstances(registry: registry).contains { $0.serverID == exact.id })
        MCPRemoteToolSource.register(configuration: exact, client: client, tools: [], registry: registry)
        #expect(registry.runner(named: VolcengineProfessionalSearch.toolName(for: exact)) == nil)
        #expect(!VolcengineProfessionalSearch.registeredInstances(registry: registry).contains { $0.serverID == exact.id })
        MCPRemoteToolSource.unregister(configuration: exact, registry: registry)
    }

    @Test("Professional selector is exact and native read classification stays identity-stable")
    func professionalSelectorAndClassificationAreExact() throws {
        #expect(ProfessionalSearchAuthority.requestsProfessionalSource(
            argumentsJSON: Data(#"{"query":"q","source":"professional"}"#.utf8)))
        for json in [
            #"{"query":"q","source":"web"}"#, #"{"query":"q"}"#,
            #"{"query":"q","source":"Professional"}"#, #"{"source":true}"#,
            "[]", "not json",
        ] {
            #expect(!ProfessionalSearchAuthority.requestsProfessionalSource(
                argumentsJSON: Data(json.utf8)), Comment(rawValue: json))
        }
        let base = AnyAgentTool(WebSearchTool(service: WebSearchService())).descriptor
        #expect(!base.isSideEffecting)
        #expect(base.effect == .readOnly)
        #expect(base.riskLabels == [.networkAccess])
        #expect(TemporaryChatToolPolicy.isReadOnlySafe(base))
        // Public-web projection retains the exact base descriptor identity;
        // source=professional is denied by arguments, never by a copied and
        // rehashed approval descriptor.
        #expect(TemporaryChatToolPolicy.readOnlyDescriptor(base)?.authorizationIdentity
            == base.authorizationIdentity)
        let professional = Data(#"{"query":"q","source":"professional"}"#.utf8)
        #expect(TemporaryChatToolPolicy.denialReason(
            descriptor: base, arguments: professional) != nil)
        #expect(ChatToolPolicy.denialReason(
            descriptor: base, arguments: professional, resourceContext: nil) != nil)
        for json in [#"{"query":"q"}"#, #"{"query":"q","source":"web"}"#] {
            #expect(TemporaryChatToolPolicy.denialReason(
                descriptor: base, arguments: Data(json.utf8)) == nil)
            #expect(ChatToolPolicy.denialReason(
                descriptor: base, arguments: Data(json.utf8), resourceContext: nil) == nil)
        }
    }

    @Test("Professional account state is isolated by registry and unregister is scoped")
    func professionalRegistryIsolation() {
        let first = ToolRunnerRegistry()
        let second = ToolRunnerRegistry()
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEE01")!
        let runner: ProfessionalSearchAuthority.Runner = { _, _ in
            ToolExecutionOutput(summary: "{}", fullOutputSHA256: "")
        }
        let account = ProfessionalSearchAuthority.register(
            serverID: id, displayName: "Registry A", registry: first, runner: runner
        )
        #expect(VolcengineProfessionalSearch.registeredInstances(registry: first) == [account])
        #expect(VolcengineProfessionalSearch.registeredInstances(registry: second).isEmpty)
        #expect(!VolcengineProfessionalSearch.registeredInstances().contains { $0.serverID == id })
        let frozen = ProfessionalSearchAuthority.freeze(
            registry: first, allowedToolNames: [WebSearchTool.name]
        )
        #expect(frozen.accounts == [account])
        #expect(!frozen.isBound(to: second))
        ProfessionalSearchAuthority.unregister(serverID: id, registry: second)
        #expect(VolcengineProfessionalSearch.registeredInstances(registry: first) == [account])
        ProfessionalSearchAuthority.unregister(serverID: id, registry: first)
        #expect(VolcengineProfessionalSearch.registeredInstances(registry: first).isEmpty)
    }

    @Test("A stale visible professional alias from an earlier build is purged on unregister")
    func staleProfessionalAliasIsPurged() throws {
        let config = dataProConfiguration()
        let registry = ToolRunnerRegistry()
        // Simulate the pre-unification registration: a VISIBLE runner under
        // the same owned alias name.
        let legacyDescriptor = ToolCatalog.Descriptor(
            name: VolcengineProfessionalSearch.toolName(for: config),
            toolDescription: "legacy visible alias",
            parametersJSON: #"{"type":"object"}"#,
            riskLabels: [.networkAccess],
            isSideEffecting: true
        )
        registry.register(AnyAgentTool(descriptor: legacyDescriptor) { _, _ in
            ToolExecutionOutput(summary: "{}", fullOutputSHA256: "")
        })
        #expect(registry.allDescriptors.contains { $0.name == legacyDescriptor.name })
        MCPRemoteToolSource.unregister(configuration: config, registry: registry)
        #expect(registry.runner(named: legacyDescriptor.name) == nil)
        #expect(registry.allDescriptors.isEmpty)
        #expect(!VolcengineProfessionalSearch.registeredInstances(registry: registry).contains { $0.serverID == config.id })
    }

    @Test("Native professional denials and cancellation happen before transport")
    func professionalSearchDenialsDoNotReachTransport() async throws {
        MCPStubURLProtocol.prepare([])
        let config = dataProConfiguration()
        let client = try MCPRemoteClient(configuration: config, credential: "synthetic-test-credential", session: session())
        let registry = ToolRunnerRegistry()
        MCPRemoteToolSource.register(configuration: config, client: client, tools: [dataProTool], registry: registry)
        let tool = WebSearchTool(
            service: WebSearchService(),
            professional: MCPRegistryProfessionalSearchExecutor(registry: registry)
        )
        let arguments = try JSONDecoder().decode(
            WebSearchTool.Arguments.self,
            from: Data(#"{"query":"学术文献：AI","source":"professional"}"#.utf8)
        )
        let authority = ProfessionalSearchAuthority.freeze(
            registry: registry, allowedToolNames: [WebSearchTool.name]
        )
        func validContext() -> ToolContext {
            ToolContext(
                runID: UUID(), allowedToolNames: [WebSearchTool.name],
                professionalSearchAuthority: authority,
                cancellation: CancellationToken(),
                frozenEffectiveCatalogNames: [WebSearchTool.name]
            )
        }
        var denied = [ToolContext(
            runID: UUID(), allowedToolNames: [WebSearchTool.name],
            cancellation: CancellationToken()
        )]
        let noNames = ProfessionalSearchAuthority.freeze(
            registry: registry, allowedToolNames: []
        )
        denied.append(ToolContext(
            runID: UUID(), allowedToolNames: [],
            professionalSearchAuthority: noNames,
            cancellation: CancellationToken(), frozenEffectiveCatalogNames: []
        ))
        var publicOnly = validContext()
        publicOnly.publicWebOnly = true
        denied.append(publicOnly)
        var temporary = validContext()
        temporary.temporaryReadOnly = true
        denied.append(temporary)
        var noCatalog = validContext()
        noCatalog.frozenEffectiveCatalogNames = []
        denied.append(noCatalog)
        var cancelled = validContext()
        cancelled.cancellation.cancel()
        denied.append(cancelled)
        for context in denied {
            await #expect(throws: (any Error).self) {
                try await tool.execute(arguments, context: context)
            }
        }
        #expect(MCPStubURLProtocol.capturedRequests().isEmpty)
        await client.disconnect()
        await #expect(throws: (any Error).self) {
            try await tool.execute(arguments, context: validContext())
        }
        #expect(MCPStubURLProtocol.capturedRequests().isEmpty)
        MCPRemoteToolSource.unregister(configuration: config, registry: registry)
    }

    @Test("Native DataPro query keeps error status and bounded valid JSON")
    func professionalSearchBoundsOutputAndPreservesFailures() async throws {
        let text = String(repeating: "\"\\\n专业数据", count: 2000)
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1,
            "result": ["isError": true, "content": [["type": "text", "text": text]]]
        ])
        MCPStubURLProtocol.prepare([.init(status: 200, headers: ["Content-Type": "application/json"], body: body)])
        let config = dataProConfiguration()
        let client = try MCPRemoteClient(configuration: config, credential: "synthetic-test-credential", session: session())
        let registry = ToolRunnerRegistry()
        MCPRemoteToolSource.register(configuration: config, client: client, tools: [dataProTool], registry: registry)
        let tool = WebSearchTool(
            service: WebSearchService(),
            professional: MCPRegistryProfessionalSearchExecutor(registry: registry)
        )
        let authority = ProfessionalSearchAuthority.freeze(
            registry: registry, allowedToolNames: [WebSearchTool.name]
        )
        let context = ToolContext(
            runID: UUID(), allowedToolNames: [WebSearchTool.name],
            professionalSearchAuthority: authority,
            cancellation: CancellationToken(),
            frozenEffectiveCatalogNames: [WebSearchTool.name]
        )
        let output = try await tool.execute(
            try JSONDecoder().decode(WebSearchTool.Arguments.self, from: Data(#"{"query":"学术文献：人工智能 近三年","source":"professional"}"#.utf8)),
            context: context
        )
        #expect(output.summary.count <= 4096)
        let result = try #require(JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any])
        #expect(result["truncated"] as? Bool == true)
        #expect(result["sourceSummaryMayBeTruncated"] as? Bool == true)
        #expect(result["isError"] as? Bool == true)
        #expect(output.exitStatus == 1)

        MCPStubURLProtocol.prepare([.init(status: 500, headers: ["Content-Type": "application/json"], body: Data("synthetic failure".utf8))])
        await #expect(throws: (any Error).self) {
            try await tool.execute(
                try JSONDecoder().decode(WebSearchTool.Arguments.self, from: Data(#"{"query":"股票金融：000001.SZ 行情","source":"professional"}"#.utf8)),
                context: context
            )
        }
        MCPRemoteToolSource.unregister(configuration: config, registry: registry)
    }

    @Test("Remote MCP error bodies and messages are redacted before surfacing")
    func redactsRemoteErrorBodies() {
        let http = MCPClientError.httpError(status: 500, body: "authorization: Bearer super-secret-token")
        let httpText = http.errorDescription ?? ""
        #expect(!httpText.contains("super-secret-token"))
        #expect(httpText.contains("MCP HTTP 500"))

        let remote = MCPClientError.remoteError(code: -32_000, message: "api_key=sk-live-abcdef123456")
        let remoteText = remote.errorDescription ?? ""
        #expect(!remoteText.contains("sk-live-abcdef123456"))
        #expect(remoteText.contains("MCP error -32000"))
    }

    @Test("Transport failures distinguish cancellation, timeout phase and disconnect")
    func normalizesTransportFailures() async throws {
        if case MCPClientError.timedOut(let phase)? = MCPRemoteClient.normalized(URLError(.timedOut), phase: "call") as? MCPClientError {
            #expect(phase == "call")
        } else {
            Issue.record("expected timedOut")
        }
        if case MCPClientError.cancelled? = MCPRemoteClient.normalized(URLError(.cancelled), phase: "connect") as? MCPClientError {
            // expected
        } else {
            Issue.record("expected cancelled")
        }
        if case MCPClientError.cancelled? = MCPRemoteClient.normalized(CancellationError(), phase: "discover") as? MCPClientError {
            // expected
        } else {
            Issue.record("expected cancelled for CancellationError")
        }
        #expect(MCPRemoteClient.timeoutPhase(for: "tools/list") == "discover")
        #expect(MCPRemoteClient.timeoutPhase(for: "tools/call") == "call")
        #expect(MCPRemoteClient.timeoutPhase(for: "initialize") == "initialize")
        #expect(MCPRemoteClient.timeoutPhase(for: "other") == "request")

        let config = MCPServerConfiguration(
            displayName: "Example", endpoint: URL(string: "https://example.test/mcp")!
        )
        let client = try MCPRemoteClient(configuration: config, credential: nil, session: session())
        let before = await client.isDisconnected
        #expect(before == false)
        await client.disconnect()
        let after = await client.isDisconnected
        #expect(after == true)
        let inFlight = await client.inFlightRequests
        #expect(inFlight == 0)
        do {
            _ = try await client.discoverTools()
            Issue.record("discoverTools should fail after disconnect")
        } catch let error as MCPClientError {
            guard case .disconnected = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        } catch {
            Issue.record("unexpected non-MCP error \(error)")
        }
    }


    @Test("Disconnect does not cancel unrelated clients sharing a session")
    func sharedSessionDisconnectIsPerClient() async throws {
        MCPStubURLProtocol.prepare([
            .init(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","tools":[{"name":"read-note","description":"Read","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":true}}]}}"#.utf8)
            )
        ])
        let shared = session()
        let configA = MCPServerConfiguration(displayName: "A", endpoint: URL(string: "https://a.example.test/mcp")!)
        let configB = MCPServerConfiguration(displayName: "B", endpoint: URL(string: "https://b.example.test/mcp")!)
        let clientA = try MCPRemoteClient(configuration: configA, credential: nil, session: shared)
        let clientB = try MCPRemoteClient(configuration: configB, credential: nil, session: shared)

        await clientA.disconnect()
        let disconnectedA = await clientA.isDisconnected
        #expect(disconnectedA)

        // B must still be able to use the shared session (A never cancels tasks
        // it does not own), while A fails closed.
        let tools = try await clientB.discoverTools()
        #expect(tools.map(\.remoteName) == ["read-note"])
        do {
            _ = try await clientA.discoverTools()
            Issue.record("client A should fail closed after disconnect")
        } catch let error as MCPClientError {
            guard case .disconnected = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
    }

    @Test("Late response after disconnect cannot return success or repopulate state")
    func lateResponseAfterDisconnectFailsClosed() async throws {
        MCPStubURLProtocol.prepare([
            .init(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","tools":[]}}"#.utf8),
                delay: 0.6
            )
        ])
        let config = MCPServerConfiguration(displayName: "Slow", endpoint: URL(string: "https://slow.example.test/mcp")!)
        let client = try MCPRemoteClient(configuration: config, credential: nil, session: session())
        let task = Task { try await client.discoverTools() }
        try await Task.sleep(nanoseconds: 120_000_000)
        await client.disconnect()
        do {
            _ = try await task.value
            Issue.record("late response must not surface as success")
        } catch let error as MCPClientError {
            guard case .disconnected = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
        let tools = await (try? client.discoverTools()) ?? nil
        #expect(tools == nil)
    }

    @Test("MCP image results become verified artifacts; unsupported types are reported")
    func imageResultsBecomeArtifacts() async throws {
        let tinyPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
        let response = #"{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"image","mimeType":"image/png","data":"\#(tinyPNG)"},{"type":"image","mimeType":"image/bmp","data":"AAAA"}],"isError":false}}"#
        MCPStubURLProtocol.prepare([
            .init(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(response.utf8)
            )
        ])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPArtifactTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = MCPServerConfiguration(displayName: "Images", endpoint: URL(string: "https://images.example.test/mcp")!)
        let client = try MCPRemoteClient(
            configuration: config, credential: nil, session: session(),
            artifactRootProvider: { root }
        )
        let output = try await client.callTool(name: "screenshot", argumentsJSON: Data("{}".utf8))
        #expect(output.artifacts.count == 1)
        let artifact = try #require(output.artifacts.first)
        #expect(artifact.mimeType == "image/png")
        #expect(artifact.relativePath.hasPrefix("GeneratedImages/mcp-"))
        #expect(artifact.relativePath.hasSuffix(".png"))
        let fileURL = root.appendingPathComponent(artifact.relativePath)
        let stored = try Data(contentsOf: fileURL)
        #expect(stored.count == artifact.byteCount)
        // SHA-256 of the known 68-byte 1x1 PNG payload, computed independently
        // of the code under test.
        #expect(artifact.sha256 == "63ef318d96b5d0d0ceba6e04a4e622b1158335cdc67c49e27839132c6f655058")
        #expect(output.summary.contains("not attached"))
    }
}
