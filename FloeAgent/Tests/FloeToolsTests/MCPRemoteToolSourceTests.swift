import Foundation
import Testing
@testable import FloeTools

private final class MCPStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        var status: Int
        var headers: [String: String]
        var body: Data
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
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty { client?.urlProtocol(self, didLoad: stub.body) }
        client?.urlProtocolDidFinishLoading(self)
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

    @Test("Canvas policy exposes only bounded web tools unless MCP is explicitly granted")
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

        #expect(names == ["web.search", "web.fetch"])
        #expect(!names.contains("web.searchAI"))
        #expect(!names.contains(where: { $0.hasPrefix("browser.") }))
    }

    @Test("Canvas policy includes only enabled tools from an explicitly granted MCP server")
    func canvasPolicyFiltersMCPTools() {
        var allowed = MCPServerConfiguration(
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

        #expect(names == ["web.search", "web.fetch", expected])
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
}
