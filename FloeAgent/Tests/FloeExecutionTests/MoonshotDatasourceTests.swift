import Foundation
import Testing
@testable import FloeCore
@testable import FloeTools
@testable import FloeExecution

@Suite("Moonshot channels and Kimi Datasource", .serialized)
struct MoonshotDatasourceTests {
    private let key = "synthetic-code-key"
    private let description = """
    # arxiv
    ### search_papers
    **Required Parameters:**
    - `query` (string)
    - `file_path` (string)
    **Optional Parameters:**
    - `max_results` (integer)
    """

    private actor Fixture {
        var responses: [KimiDatasourceClient.Response]
        var requests: [URLRequest] = []
        init(_ responses: [KimiDatasourceClient.Response]) { self.responses = responses }
        func send(_ request: URLRequest) throws -> KimiDatasourceClient.Response {
            requests.append(request)
            guard !responses.isEmpty else { throw URLError(.badServerResponse) }
            return responses.removeFirst()
        }
        func recorded() -> [URLRequest] { requests }
    }

    private func data(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys])
    }

    private func client(_ fixture: Fixture) throws -> KimiDatasourceClient {
        try KimiDatasourceClient(providerID: UUID(), baseURL: URL(string: "https://api.kimi.com/coding/v1")!,
            identity: .init(version: "test", deviceName: "test", deviceModel: "test",
                            osVersion: "test", deviceID: UUID().uuidString),
            keyResolver: { "synthetic-code-key" },
            transport: { request, _ in try await fixture.send(request) })
    }

    private func configuration(_ channel: MoonshotSearchOptions.Channel) throws -> WebSearchProviderConfiguration {
        let id = UUID()
        let options = ["interface": channel.rawValue]
        return try .init(id: id, kind: .moonshot, displayName: "Moonshot " + channel.rawValue,
            credentialAccount: MoonshotSearchOptions(options: options).credentialAccount(providerID: id),
            options: options)
    }

    @Test("Brand channels use different keys, fixed endpoints and real caller identity")
    func channelRequests() throws {
        let code = try configuration(.kimiCode)
        let payg = try configuration(.payg)
        let codeKey = WebSearchCredential(values: ["apiKey": key, "moonshotChannel": "kimiCode"])
        let paygKey = WebSearchCredential(values: ["apiKey": "synthetic-payg", "moonshotChannel": "payg"])
        let codeRequest = try WebSearchService.makeRequest(code, credential: codeKey, query: .init(text: "Python", maxResults: 1))
        let paidRequest = try WebSearchService.makeRequest(payg, credential: paygKey, query: .init(text: "Python", maxResults: 1))
        #expect(codeRequest.url?.absoluteString == "https://api.kimi.com/coding/v1/search")
        #expect(paidRequest.url?.absoluteString == "https://api.moonshot.cn/v1/tools/search")
        #expect(codeRequest.value(forHTTPHeaderField: "X-Msh-Platform") == "floe-agent-ios")
        #expect(codeRequest.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("FloeAgent/") == true)
        #expect(codeRequest.timeoutInterval == 120)
        let codeData = try #require(codeRequest.httpBody)
        let paidData = try #require(paidRequest.httpBody)
        let codeBody = try #require(JSONSerialization.jsonObject(with: codeData) as? [String: Any])
        let paidBody = try #require(JSONSerialization.jsonObject(with: paidData) as? [String: Any])
        #expect(Set(codeBody.keys) == ["text_query"])
        #expect(paidBody["limit"] as? Int == 1)
        #expect(paidBody["include_content"] as? Bool == false)
        #expect(code.credentialAccount != payg.credentialAccount)
        let sameIDPaid = try MoonshotSearchOptions(options: ["interface": "payg"]).credentialAccount(providerID: code.id)
        #expect(sameIDPaid != code.credentialAccount)
        #expect(throws: (any Error).self) {
            try WebSearchService.makeRequest(code, credential: paygKey, query: .init(text: "x"))
        }
        var altered = code
        altered.endpoint = URL(string: "https://api.moonshot.cn/v1/tools/search")
        #expect(throws: (any Error).self) {
            try WebSearchService.makeRequest(altered, credential: codeKey, query: .init(text: "x"))
        }
    }

    @Test("Provider content and authority labels remain unverified search metadata")
    func publicResultContract() throws {
        let payload = try data(["search_results": [[
            "title": "Example", "url": "https://example.com/a", "snippet": "index snippet",
            "content": "provider body", "authority": "official", "site_name": "Example", "icon": "https://example.com/icon"
        ]]])
        let parsed = try WebSearchService.parseOutput(payload, provider: .moonshot, limit: 1)
        let row = try #require(parsed.results.first)
        #expect(row.content == "provider body")
        #expect(row.authorityLabel == "official")
        #expect(row.effectiveContentState == .searchMetadataOnly)
        let output = try WebSearchTool.output(.init(query: "x", results: parsed.results, providersUsed: [.moonshot]))
        #expect(output.capturedOutput?.contains("provider body") == true)
        #expect(output.capturedOutput?.contains("authorityLabel") == true)
        #expect(throws: (any Error).self) {
            try WebSearchService.parseOutput(Data("{}".utf8), provider: .moonshot, limit: 1)
        }
    }

    private final class HostRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ host: String) { lock.lock(); storage.append(host); lock.unlock() }
        var hosts: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    @Test("Failed Code search never falls back to the PAYG channel")
    func noCrossChannelFallback() async throws {
        let code = try configuration(.kimiCode)
        let payg = try configuration(.payg)
        let pairs: [(WebSearchProviderConfiguration, WebSearchCredential)] = [
            (code, .init(values: ["apiKey": key, "moonshotChannel": "kimiCode"])),
            (payg, .init(values: ["apiKey": "synthetic-paid", "moonshotChannel": "payg"]))
        ]
        let recorder = HostRecorder()
        let service = WebSearchService(configuration: .ephemeral, configurations: { pairs },
            validateDestination: { url, _ in recorder.append(url.host ?? ""); throw URLError(.cannotConnectToHost) })
        await #expect(throws: (any Error).self) { try await service.search(.init(text: "x")) }
        #expect(recorder.hosts == ["api.kimi.com"])
    }

    @Test("JSON-string description enables one typed query and captures files without saving")
    func descriptionThenQuery() async throws {
        let fixture = Fixture([
            .init(status: 200, data: try data(description)),
            .init(status: 200, data: try data(["is_success": true,
                "result": ["assistant": [["type": "text", "text": "one row"]]],
                "files": [["name": "/server/arbitrary/result.csv", "content": "title\nPaper\n"]]]))
        ])
        let client = try client(fixture)
        let context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        let described = try await client.execute(.init(action: .describe, name: "arxiv"), context: context)
        #expect(described.summary.contains("descriptionReady"))
        let output = try await client.execute(.init(action: .query, name: "arxiv", apiName: "search_papers",
            parameters: ["query": .string("retrieval"), "max_results": .number(1)]), context: context)
        let capture = try #require(output.capturedOutput)
        #expect(capture.contains("querySucceeded"))
        #expect(capture.contains("\"filesImported\":false"))
        #expect(capture.contains("\"saved\":false"))
        #expect(!capture.contains("/server/arbitrary"))
        #expect(output.summary.count <= 4_096)
        _ = try JSONSerialization.jsonObject(with: Data(output.summary.utf8))
        let requests = await fixture.recorded()
        #expect(requests.count == 2)
        #expect(requests[0].timeoutInterval == 30)
        #expect(requests[1].timeoutInterval == 120)
        let requestData = try #require(requests[1].httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        let outer = try #require(body["params"] as? [String: Any])
        let params = try #require(outer["params"] as? [String: Any])
        #expect(params["max_results"] as? Int == 1)
        #expect((params["file_path"] as? String)?.hasPrefix("/tmp/floe-datasource-") == true)
        await #expect(throws: (any Error).self) {
            try await client.execute(.init(action: .query, name: "arxiv", apiName: "search_papers",
                parameters: ["query": .string("x")]), context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        }
        #expect(await fixture.recorded().count == 2)
    }

    @Test("Raw methods, model file paths and excessive result counts are rejected")
    func requestBounds() throws {
        for operation in [
            ProfessionalDatasetRequest(action: .describe, name: "unknown"),
            .init(action: .describe, name: "arxiv", parameters: [:]),
            .init(action: .query, name: "arxiv", apiName: "search_papers",
                  parameters: ["file_path": .string("/etc/a")]),
            .init(action: .query, name: "arxiv", apiName: "search_papers",
                  parameters: ["max_results": .number(11)])
        ] {
            #expect(throws: (any Error).self) { try operation.validate() }
        }
    }

    @Test("Oversized file metadata preserves a valid bounded summary and full capture")
    func boundedFileMetadata() async throws {
        let name = String(repeating: "\"", count: 190) + ".csv"
        let files = (0..<10).map { _ in ["name": name, "content": "row"] }
        let fixture = Fixture([
            .init(status: 200, data: try data(description)),
            .init(status: 200, data: try data(["is_success": true,
                "result": ["assistant": [["type": "text", "text": "rows"]]], "files": files]))
        ])
        let client = try client(fixture)
        let context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        _ = try await client.execute(.init(action: .describe, name: "arxiv"), context: context)
        let result = try await client.execute(.init(action: .query, name: "arxiv", apiName: "search_papers",
            parameters: ["query": .string("paper"), "max_results": .number(1)]), context: context)
        #expect(result.summary.count <= 4_096)
        let preview = try #require(JSONSerialization.jsonObject(with: Data(result.summary.utf8)) as? [String: Any])
        #expect(preview["fileCount"] as? Int == 10)
        let capture = try #require(result.capturedOutput)
        let full = try #require(JSONSerialization.jsonObject(with: Data(capture.utf8)) as? [String: Any])
        #expect((full["files"] as? [[String: Any]])?.count == 10)
    }

    @Test("HTTP failures are structured, redacted and never retried")
    func errors() async throws {
        let fixture = Fixture([.init(status: 403, data: try data([
            "error": ["code": "permission_denied", "message": "rejected " + key]
        ]), requestID: "synthetic-trace")])
        let output = try await client(fixture).execute(.init(action: .describe, name: "arxiv"),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        #expect(output.exitStatus == 1)
        #expect(output.capturedOutput?.contains("permission_denied") == true)
        #expect(output.capturedOutput?.contains(key) == false)
        #expect(await fixture.recorded().count == 1)
    }

    @Test("Cancellation stops an in-flight query without returning success")
    func cancellation() async throws {
        let token = CancellationToken()
        let client = try KimiDatasourceClient(providerID: UUID(), baseURL: URL(string: "https://api.kimi.com/coding/v1")!,
            identity: .init(version: "test", deviceName: "test", deviceModel: "test", osVersion: "test", deviceID: "test"),
            keyResolver: { "synthetic-code-key" }, transport: { _, _ in
                try await Task.sleep(for: .seconds(20))
                return .init(status: 200, data: Data())
            })
        let task = Task {
            try await client.execute(.init(action: .describe, name: "arxiv"),
                context: ToolContext(runID: UUID(), cancellation: token))
        }
        try await Task.sleep(for: .milliseconds(30))
        token.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
    }

    @Test("HTTP 200 business errors retain the provider's text channel")
    func businessErrorChannel() async throws {
        let fixture = Fixture([.init(status: 200, data: try data([
            "is_success": false,
            "error": ["assistant": [["type": "text", "text": "Required field query is missing"]]]
        ]))])
        let output = try await client(fixture).execute(.init(action: .describe, name: "arxiv"),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        #expect(output.exitStatus == 1)
        #expect(output.capturedOutput?.contains("Required field query is missing") == true)
        #expect(await fixture.recorded().count == 1)
    }

    @Test("Same web.search reaches Code and frozen restrictions remain enforced")
    func integratedTool() async throws {
        let registry = ToolRunnerRegistry()
        let account = ProfessionalSearchAuthority.registerKimiCode(providerID: UUID(), displayName: "Code", registry: registry) { operation, _ in
            ToolExecutionOutput(summary: operation.name, fullOutputSHA256: "synthetic")
        }
        let frozen = ProfessionalSearchAuthority.freeze(registry: registry, allowedToolNames: ["web.search"])
        let context = ToolContext(runID: UUID(), allowedToolNames: ["web.search"],
            professionalSearchAuthority: frozen, cancellation: CancellationToken(), frozenEffectiveCatalogNames: ["web.search"])
        let tool = WebSearchTool(service: WebSearchService(), professional: MCPRegistryProfessionalSearchExecutor(registry: registry))
        let args = try JSONDecoder().decode(WebSearchTool.Arguments.self, from: Data("""
        {"query":"papers","source":"professional","provider":"Code","dataset":{"action":"describe","name":"arxiv"}}
        """.utf8))
        try tool.validate(args)
        let output = try await tool.execute(args, context: context)
        #expect(output.summary == "arxiv")
        var restricted = context
        restricted.publicWebOnly = true
        await #expect(throws: (any Error).self) { try await tool.execute(args, context: restricted) }
        ProfessionalSearchAuthority.unregisterKimiCode(providerID: account.serverID, registry: registry)
        await #expect(throws: (any Error).self) { try await tool.execute(args, context: context) }
    }

    @Test("Bundled catalog has one Moonshot brand with two channel choices")
    func catalogBrand() throws {
        let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try SearchProviderCatalogIndex.validated(from: Data(contentsOf:
            root.appendingPathComponent("FloeApp/Resources/SearchProviderCatalog.json")))
        let matches = catalog.entries.filter { $0.adapterKind == "moonshot" }
        #expect(matches.count == 1)
        let entry = try #require(matches.first)
        #expect(entry.name["en"] == "Moonshot AI")
        #expect(entry.name["zh-Hans"] == "月之暗面")
        #expect(entry.optionFields.first(where: { $0.key == "interface" })?.allowedValues == ["payg", "kimiCode"])
        let draft = try #require(SearchProviderDraftFactory.draftInstance(for: entry, localePrimary: "en"))
        #expect(draft.configuration.kind == .moonshot)
        #expect(!draft.configuration.enabled)
        let options = try MoonshotSearchOptions(options: draft.configuration.options)
        #expect(draft.configuration.credentialAccount == options.credentialAccount(providerID: draft.configuration.id))
    }

    @Test("DataPro still receives only its exact query and rejects dataset dispatch")
    func dataProRemainsQueryOnly() async throws {
        let registry = ToolRunnerRegistry()
        let account = ProfessionalSearchAuthority.register(serverID: UUID(), displayName: "DataPro", registry: registry) { data, _ in
            let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
            #expect(payload == ["query": "exact question"])
            return ToolExecutionOutput(summary: "DataPro", fullOutputSHA256: "synthetic")
        }
        let authority = ProfessionalSearchAuthority.freeze(registry: registry, allowedToolNames: ["web.search"])
        let context = ToolContext(runID: UUID(), allowedToolNames: ["web.search"],
            professionalSearchAuthority: authority, cancellation: CancellationToken(), frozenEffectiveCatalogNames: ["web.search"])
        let result = try await ProfessionalSearchAuthority.execute(registry: registry, authority: authority,
            account: account, query: "exact question", context: context)
        #expect(result.summary == "DataPro")
        await #expect(throws: (any Error).self) {
            try await ProfessionalSearchAuthority.execute(registry: registry, authority: authority,
                account: account, query: "exact question", dataset: .init(action: .describe, name: "arxiv"), context: context)
        }
    }
}
