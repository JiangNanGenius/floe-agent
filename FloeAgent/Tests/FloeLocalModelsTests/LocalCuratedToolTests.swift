// FloeLocalModelsTests — Build 236 curated local toolset.
//
// Focused deterministic coverage of bounded on-device tool presentation:
//   * an explicit Chinese news search presents web.search ahead of file tools,
//   * a follow-up search after a settled result runs a new search call,
//   * a tight per-window schema budget keeps search (news) or read tools
//     (file intent) and never silently swaps them,
//   * a web.search pruned by the request's schema budget produces the
//     request-scoped truthful notice (not a claim about device configuration),
//   * a direct-URL fetch keeps web.fetch and is not mistaken for search,
//   * authorized tools remain in the directory independently of schema selection.
//
// No weights, network or real model: the adapter builds prompts from
// synthetic descriptors.

import Foundation
import Testing
@testable import FloeLocalModels
@testable import FloeProviders
import FloeCore
import FloeModels
import FloeTools

@available(macOS 15.4, iOS 26.0, *)
private enum CuratedFixtures {
    static let modelID = "qwen3.8-4b-heretic-mlx4"

    static func model(contextTokens: Int = 8_192, outputTokens: Int = 1_024) -> ModelProfile {
        ModelProfile(
            providerID: LocalProviderAdapter.providerProfile.id,
            remoteModelID: modelID,
            displayName: "Synthetic local",
            limits: .init(contextTokens: contextTokens, maxOutputTokens: outputTokens),
            capabilities: [.text, .tools]
        )
    }

    static let readFile = ToolSchemaDescriptor(
        name: "workspace.readFile", description: "Read a workspace file",
        parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#
    )
    static let listDirectory = ToolSchemaDescriptor(
        name: "workspace.listDirectory", description: "List a workspace directory",
        parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}}}"#
    )
    static let searchFiles = ToolSchemaDescriptor(
        name: "workspace.searchFiles", description: "Search workspace files",
        parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#
    )
    static let inspectMetadata = ToolSchemaDescriptor(
        name: "workspace.inspectFileMetadata", description: "Inspect file metadata",
        parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}}}"#
    )
    static let webSearch = ToolSchemaDescriptor(
        name: "web.search", description: "Search the web",
        parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#
    )
    static let webFetch = ToolSchemaDescriptor(
        name: "web.fetch", description: "Fetch readable page content",
        parametersJSON: #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}"#
    )

    static let readChain = [readFile, listDirectory, searchFiles, inspectMetadata]

    static func request(
        userText: String,
        contextTokens: Int = 8_192,
        outputTokens: Int = 1_024,
        toolSchemas: [ToolSchemaDescriptor],
        replayedToolPairs: [ReplayedToolPair] = []
    ) -> ProviderStreamRequest {
        ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: model(contextTokens: contextTokens, outputTokens: outputTokens),
            messages: [
                ("system", "Runtime envelope: synthetic workspace."),
                ("user", userText)
            ],
            replayedToolPairs: replayedToolPairs,
            toolSchemas: toolSchemas,
            allToolNames: toolSchemas.map(\.name)
        )
    }
}

@Suite("Local curated toolset")
struct LocalCuratedToolTests {
    @Test("A Chinese news search presents web.search ahead of the read chain")
    @available(macOS 15.4, iOS 26.0, *)
    func chineseNewsSearchPrioritizesWebSearch() {
        let schemas = CuratedFixtures.readChain + [CuratedFixtures.webSearch]
        let build = LocalProviderAdapter.buildPrompt(for: CuratedFixtures.request(
            userText: "帮我搜索一下今天的新闻",
            toolSchemas: schemas
        ))
        #expect(build.requiresToolCall)
        // Admission priority keeps web.search in the offered set (the old
        // pinned file/Linux set crowded it out entirely); the intended forced
        // tool is the scored primary repair tool.
        #expect(build.selectedTools.map(\.name).contains("web.search"))
        #expect(build.primaryRepairTool?.name == "web.search")
        #expect(build.systemInstructions.contains("- web.search:"))
    }

    @Test("A follow-up search after a settled result runs a distinct new search")
    @available(macOS 15.4, iOS 26.0, *)
    func followUpSearchRunsNewCall() throws {
        let earlierCall = try ToolCall(
            id: "search-earlier", toolName: "web.search",
            argumentsJSON: Data(#"{"query":"今天新闻"}"#.utf8), scope: .local
        )
        let earlierResult = ToolResult(
            callID: "search-earlier", status: .ok,
            outputSummary: "3 results", outputDigest: "digest"
        )
        let schemas = CuratedFixtures.readChain + [CuratedFixtures.webSearch]
        let build = LocalProviderAdapter.buildPrompt(for: CuratedFixtures.request(
            userText: "很好，再搜索一下明天的天气",
            toolSchemas: schemas,
            replayedToolPairs: [ReplayedToolPair(call: earlierCall, result: earlierResult)]
        ))
        #expect(build.requiresToolCall, "a follow-up search needs its own call")
        #expect(build.selectedTools.map(\.name).contains("web.search"))
        // The settled pair is referenced, never substituted for the new call.
        #expect(build.text.contains("EARLIER TOOL CALL web.search"))
    }

    @Test("A tight budget keeps web.search for news and read tools for file lookup")
    @available(macOS 15.4, iOS 26.0, *)
    func tightBudgetKeepsIntentTool() {
        let schemas = CuratedFixtures.readChain + [CuratedFixtures.webSearch]
        // A realistic tight-tier probe: a 2K context with a 1K output reserve
        // leaves ~1K for the ENTIRE complete-definition prompt. The former
        // fixture assumed a static schema-character cap that did not count
        // complete definitions or the envelope protocol, so use a 512-token
        // generation reserve here instead of pretending 1K is available.
        let newsBuild = LocalProviderAdapter.buildPrompt(for: CuratedFixtures.request(
            userText: "搜索今天的新闻",
            contextTokens: 2_048,
            outputTokens: 512,
            toolSchemas: schemas
        ))
        #expect(newsBuild.selectedTools.map(\.name).contains("web.search"))
        #expect(newsBuild.requiresToolCall)
        #expect(!newsBuild.exceedsContextWindow)

        let fileBuild = LocalProviderAdapter.buildPrompt(for: CuratedFixtures.request(
            userText: "搜索工作区目录里的文件",
            contextTokens: 2_048,
            outputTokens: 512,
            toolSchemas: schemas
        ))
        let names = Set(fileBuild.selectedTools.map(\.name))
        #expect(names.contains("workspace.readFile"))
        #expect(names.contains("workspace.listDirectory"))
        #expect(!names.contains("web.search"), "file intent wins the tight budget")
        #expect(!fileBuild.exceedsContextWindow)
    }

    @Test("A budget-pruned web.search yields a request-scoped truthful notice")
    @available(macOS 15.4, iOS 26.0, *)
    func budgetPrunedSearchIsTruthful() {
        // A web.search schema whose own COMPLETE definition cannot fit the
        // actual remaining schema budget (distinct from an unconfigured
        // provider). The old 1 400-character fixture only exceeded the removed
        // static character cap; the real 2 048-token window can carry it.
        let padding = String(repeating: "q", count: 8_000)
        let fatSearch = ToolSchemaDescriptor(
            name: "web.search",
            description: "Search the web",
            parametersJSON: #"{"type":"object","properties":{"padding":{"type":"string","description":""# + "\"\(padding)\"" + #"}},"required":["query"]}"#
        )
        let build = LocalProviderAdapter.buildPrompt(for: CuratedFixtures.request(
            userText: "搜索今天的新闻",
            contextTokens: 2_048,
            toolSchemas: [fatSearch, CuratedFixtures.readFile]
        ))
        #expect(!build.selectedTools.map(\.name).contains("web.search"))
        #expect(build.systemInstructions.contains("WEB SEARCH UNAVAILABLE FOR THIS REQUEST"))
        // Request-scoped wording: does not assert the device configuration.
        #expect(build.systemInstructions.contains("pruned by the current schema budget"))
        #expect(!build.systemInstructions.contains("WEB SEARCH NOT CONFIGURED"))
        // The read tool is not forced as a substitute.
        #expect(!build.requiresToolCall)
    }

    @Test("A direct-URL fetch keeps web.fetch and is not treated as search")
    @available(macOS 15.4, iOS 26.0, *)
    func directURLFetchKeepsWebFetch() {
        let build = LocalProviderAdapter.buildPrompt(for: CuratedFixtures.request(
            userText: "请抓取 https://example.com 的网页内容并总结",
            toolSchemas: [CuratedFixtures.webFetch, CuratedFixtures.readFile]
        ))
        #expect(build.selectedTools.map(\.name).contains("web.fetch"))
        #expect(!build.systemInstructions.contains("WEB SEARCH UNAVAILABLE"))
    }

    @Test("Authorized tools remain callable independently of the selected schema subset")
    @available(macOS 15.4, iOS 26.0, *)
    func authorizedToolsRemainAvailable() {
        let schemas = [
            "exec.shell", "environment.startLinux",
            "environment.hardRestartLinux", "workspace.applyPatch",
            "workspace.createFile", "workspace.writeFile", "workspace.deleteFile",
            "notes.edit", "image.ocr", "git.commit", "ssh.execute"
        ].map { ToolSchemaDescriptor(name: $0, description: "Complex tool") }
        let build = LocalProviderAdapter.buildPrompt(for: CuratedFixtures.request(
            userText: "帮我运行这些复杂操作",
            toolSchemas: schemas
        ))
        let authorized = Set(schemas.map(\.name))
        #expect(Set(build.fallbackTools.map(\.name)) == authorized)
        #expect(Set(build.selectedTools.map(\.name)).isSubset(of: authorized))
        #expect(build.selectedTools.contains { $0.name == "exec.shell" })
        #expect(build.requiresToolCall)
    }
}
