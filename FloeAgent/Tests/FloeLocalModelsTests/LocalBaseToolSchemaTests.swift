// FloeLocalModelsTests — stable curated tool schemas for on-device models.
//
// Device evidence (Build 235): a "search today's news" turn picked
// workspace.listDirectory instead of web.search, then claimed search was
// unavailable. The curated pinned set (web search + read-only file lookup)
// must therefore be offered on every relevant run without a discovery
// round-trip, in intent-specific admission order, stay available on
// follow-ups, and remain inside the per-window budgets the prompt pressure
// model enforces.

import Foundation
import Testing
@testable import FloeLocalModels
@testable import FloeProviders
import FloeCore
import FloeModels
import FloeTools

@Suite("FloeLocalModels.BaseToolSchemas")
struct LocalBaseToolSchemaTests {
    private static let baseTools: [ToolSchemaDescriptor] = [
        .init(name: "workspace.listDirectory",
              description: "List workspace directory entries",
              parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"additionalProperties":false}"#),
        .init(name: "workspace.readFile",
              description: "Read a workspace file",
              parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}"#),
        .init(name: "workspace.searchFiles",
              description: "Search workspace files",
              parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}"#),
        .init(name: "workspace.inspectFileMetadata",
              description: "Inspect file metadata",
              parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}"#),
        .init(name: "web.search", description: "Search the web",
              parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}"#),
        .init(name: "environment.prepareLinux",
              description: "Install the App-provided Linux image",
              parametersJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#)
    ]

    @available(macOS 15.4, *)
    private static func mlxModel(contextTokens: Int) -> ModelProfile {
        ModelProfile(
            providerID: LocalProviderAdapter.providerProfile.id,
            remoteModelID: "qwen3.8-4b-distill-heretic-mlx-4bit",
            displayName: "Qwen local",
            limits: .init(contextTokens: contextTokens, maxOutputTokens: 1_024),
            capabilities: [.text, .tools]
        )
    }

    @available(macOS 15.4, *)
    private static func request(
        userText: String,
        contextTokens: Int = 8_192,
        toolResults: [(callID: String, output: String)] = [],
        pendingToolCalls: [ToolCall] = [],
        replayedToolPairs: [ReplayedToolPair] = []
    ) -> ProviderStreamRequest {
        ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: mlxModel(contextTokens: contextTokens),
            messages: [
                ("system", "You are Floe. Runtime envelope."),
                ("user", userText)
            ],
            toolResults: toolResults,
            pendingToolCalls: pendingToolCalls,
            replayedToolPairs: replayedToolPairs,
            toolSchemas: baseTools,
            allToolNames: baseTools.map(\.name)
        )
    }

    /// The exact Build 235 failure: an explicit news-search request must
    /// already see web.search (first in admission), with no tools.list call,
    /// and never the Linux preparation capability.
    @Test("A news-search request receives web.search without tools.list and no provisioning tool")
    @available(macOS 15.4, *)
    func baseSchemasWithoutDiscovery() {
        let build = LocalProviderAdapter.buildPrompt(
            for: Self.request(userText: "搜索一下今天的新闻")
        )
        let selected = build.selectedTools
        let selectedNames = Set(selected.map(\.name))
        #expect(selectedNames.contains("web.search"), "web.search must be offered on the first run")
        // The intended forced tool is the scored primary repair tool.
        #expect(build.primaryRepairTool?.name == "web.search")
        for name in LocalModelToolPolicy.pinnedToolNames {
            #expect(selectedNames.contains(name), "\(name) belongs to the pinned base set")
        }
        // Hidden complex tools never enter via the base set.
        #expect(!selectedNames.contains("environment.prepareLinux"))
        // Complete schemas travel, not just names.
        for tool in selected {
            #expect(!tool.parametersJSON.isEmpty)
            #expect(!tool.description.isEmpty)
        }
        #expect(build.requiresToolCall, "an action request with offered tools must require a call")
        #expect(build.systemInstructions.contains("OFFERED TOOLS FOR THIS TURN"))
        #expect(build.systemInstructions.contains("web.search"))
        // No discovery round-trip is required for these. The truthful-completion
        // rule names the receipt explicitly (Build 222 bounded protocol).
        #expect(build.systemInstructions.contains("never claim"))
        #expect(build.systemInstructions.contains("TOOL RESULT with the same call id"))
    }

    /// A file-lookup request admits the read chain ahead of web.search, so in
    /// a tight window that only holds three schemas, the generic "搜索 …文件"
    /// turn keeps the file tools and web.search is dropped, not the reverse.
    @Test("A file-search request spends the tight budget on read tools")
    @available(macOS 15.4, *)
    func fileRequestLeadsReadTools() {
        let build = LocalProviderAdapter.buildPrompt(
            for: Self.request(
                userText: "搜索工作区里的文件，列出目录",
                contextTokens: 2_048
            )
        )
        let names = Set(build.selectedTools.map(\.name))
        #expect(names.contains("workspace.readFile"))
        #expect(names.contains("workspace.listDirectory"))
        #expect(names.contains("workspace.searchFiles"))
        #expect(!names.contains("web.search"), "the file intent must win the tight budget")
    }

    /// The read chain: after a settled tool result, the read tools stay
    /// available so the model can follow up on what it found.
    @Test("Read-tool schemas stay offered after a tool result")
    @available(macOS 15.4, *)
    func chainSchemasSurviveToolResults() throws {
        let listed = try ToolCall(
            id: "call-list",
            toolName: "workspace.listDirectory",
            argumentsJSON: Data(#"{"path":"."}"#.utf8),
            scope: .local
        )
        let build = LocalProviderAdapter.buildPrompt(
            for: Self.request(
                userText: "读取刚才目录里的文件并告诉我内容",
                toolResults: [("call-list", "{\"status\":\"ok\",\"entries\":[\"test.txt\"]}")],
                pendingToolCalls: [listed]
            )
        )
        let selected = Set(build.selectedTools.map(\.name))
        #expect(selected.contains("workspace.listDirectory"))
        #expect(selected.contains("workspace.readFile"))
        // The receipt is rendered as evidence for the follow-up turn.
        let envelope = build.systemInstructions + "\n" + build.text
        #expect(envelope.contains("TOOL RESULT call-list"))
        #expect(build.systemInstructions.contains("workspace.readFile"))
    }

    /// Context/compaction limits are preserved: the pinned set is admitted
    /// inside the existing per-window schema budget, never on top of it.
    @Test("The pinned set respects the small-window schema budget")
    @available(macOS 15.4, *)
    func baseSetRespectsBudget() {
        for contextTokens in [2_048, 4_096, 8_192] {
            let build = LocalProviderAdapter.buildPrompt(
                for: Self.request(
                    userText: "搜索今天的新闻",
                    contextTokens: contextTokens
                )
            )
            let selected = build.selectedTools
            // Deterministic order keeps chat templates stable across turns.
            #expect(selected.map(\.name) == selected.map(\.name).sorted())
            #expect(!selected.isEmpty, "every window must still offer the tools it can afford")
            #expect(selected.count <= 10, "never more than the widest inventory budget")
            #expect(!build.exceedsContextWindow)
            // The critical search schema is always admitted for a live-web
            // request, even in the smallest supported window.
            #expect(selected.map(\.name).contains("web.search"))
        }
    }

    /// Ordinary chat must not be turned into a tool invocation.
    @Test("A greeting does not become a tool turn")
    @available(macOS 15.4, *)
    func greetingStaysConversational() {
        let build = LocalProviderAdapter.buildPrompt(for: Self.request(userText: "你好，今天过得怎么样？"))
        #expect(!build.requiresToolCall)
        #expect(build.requiresToolCall == false)
    }
}
