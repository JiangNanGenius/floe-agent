// FloeLocalModelsTests — Build 236 curated local toolset.
//
// Focused deterministic coverage of the curated on-device ceiling:
//   * an explicit Chinese news search presents web.search ahead of file tools,
//   * a follow-up search after a settled result runs a new search call,
//   * a tight per-window schema budget keeps search (news) or read tools
//     (file intent) and never silently swaps them,
//   * a web.search pruned by the request's schema budget produces the
//     request-scoped truthful notice (not a claim about device configuration),
//   * a direct-URL fetch keeps web.fetch and is not mistaken for search,
//   * complex tools never enter the authoritative directory.
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

    static func model(contextTokens: Int = 8_192) -> ModelProfile {
        ModelProfile(
            providerID: LocalProviderAdapter.providerProfile.id,
            remoteModelID: modelID,
            displayName: "Synthetic local",
            limits: .init(contextTokens: contextTokens, maxOutputTokens: 1_024),
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
        toolSchemas: [ToolSchemaDescriptor],
        replayedToolPairs: [ReplayedToolPair] = []
    ) -> ProviderStreamRequest {
        ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: model(contextTokens: contextTokens),
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
        let newsBuild = LocalProviderAdapter.buildPrompt(for: CuratedFixtures.request(
            userText: "搜索今天的新闻",
            contextTokens: 2_048,
            toolSchemas: schemas
        ))
        #expect(newsBuild.selectedTools.map(\.name).contains("web.search"))
        #expect(newsBuild.requiresToolCall)

        let fileBuild = LocalProviderAdapter.buildPrompt(for: CuratedFixtures.request(
            userText: "搜索工作区目录里的文件",
            contextTokens: 2_048,
            toolSchemas: schemas
        ))
        let names = Set(fileBuild.selectedTools.map(\.name))
        #expect(names.contains("workspace.readFile"))
        #expect(names.contains("workspace.listDirectory"))
        #expect(!names.contains("web.search"), "file intent wins the tight budget")
    }

    @Test("A budget-pruned web.search yields a request-scoped truthful notice")
    @available(macOS 15.4, iOS 26.0, *)
    func budgetPrunedSearchIsTruthful() {
        // A web.search schema whose own definition cannot fit the schema
        // character budget (distinct from an unconfigured provider).
        let padding = String(repeating: "q", count: 1_400)
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

    @Test("Complex tools never enter the authoritative directory")
    @available(macOS 15.4, iOS 26.0, *)
    func complexToolsAreAbsent() {
        let schemas = [
            "exec.shell", "exec.localPython", "exec.javascript",
            "environment.prepareLinux", "environment.startLinux",
            "environment.hardRestartLinux", "workspace.applyPatch",
            "workspace.createFile", "workspace.writeFile", "workspace.deleteFile",
            "notes.edit", "image.ocr", "git.commit", "ssh.execute"
        ].map { ToolSchemaDescriptor(name: $0, description: "Complex tool") }
        let build = LocalProviderAdapter.buildPrompt(for: CuratedFixtures.request(
            userText: "帮我运行这些复杂操作",
            toolSchemas: schemas
        ))
        #expect(build.selectedTools.isEmpty)
        #expect(build.fallbackTools.isEmpty)
        #expect(!build.requiresToolCall)
    }
}
