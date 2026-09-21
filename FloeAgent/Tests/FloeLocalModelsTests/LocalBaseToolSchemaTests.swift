// FloeLocalModelsTests — stable base tool schemas for on-device models.
//
// Device evidence (2026-09-21): a local model called tools.list on the first
// run, then produced two prose-only turns that falsely claimed a file was
// created. The base file-tool schemas must therefore be offered on every
// relevant run without a discovery round-trip, stay available for the
// create→read chain, and remain inside the per-window budgets the prompt
// pressure model enforces.

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
        .init(name: "workspace.createFile",
              description: "Create a workspace file",
              parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"],"additionalProperties":false}"#),
        .init(name: "workspace.writeFile",
              description: "Write a workspace file",
              parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"],"additionalProperties":false}"#),
        .init(name: "workspace.applyPatch",
              description: "Apply a unified diff patch",
              parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"},"patch":{"type":"string"}},"required":["path","patch"],"additionalProperties":false}"#),
        .init(name: "environment.prepareLinux",
              description: "Install the App-provided Linux image",
              parametersJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#),
        .init(name: "web.search", description: "Search the web",
              parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"additionalProperties":false}"#),
        .init(name: "notes.read", description: "Read a note",
              parametersJSON: #"{"type":"object","properties":{"id":{"type":"string"}},"additionalProperties":false}"#)
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

    /// The exact first-run failure: an action request must already see the
    /// complete file schemas, with no tools.list call.
    @Test("A file action request receives the full base schemas without tools.list")
    @available(macOS 15.4, *)
    func baseSchemasWithoutDiscovery() {
        let build = LocalProviderAdapter.buildPrompt(
            for: Self.request(userText: "试一下创建一个文本文件并保存")
        )
        let selected = Set(build.selectedTools.map(\.name))
        for name in LocalModelToolPolicy.baseFileToolNames {
            #expect(selected.contains(name), "\(name) must be offered on the first run")
        }
        #expect(selected.contains(LocalModelToolPolicy.prepareLinuxToolName))
        // Complete schemas travel, not just names.
        for tool in build.selectedTools {
            #expect(!tool.parametersJSON.isEmpty || tool.name == "environment.prepareLinux")
            #expect(!tool.description.isEmpty)
        }
        #expect(build.requiresToolCall, "an action request with offered tools must require a call")
        #expect(build.systemInstructions.contains("OFFERED TOOLS FOR THIS TURN"))
        #expect(build.systemInstructions.contains("workspace.createFile"))
        // No discovery round-trip is required for these.
        #expect(build.systemInstructions.contains("never claim an action succeeded without a tool result"))
    }

    /// The create→read chain: after a settled tool result, the same wiring
    /// tools stay available so the model can read back what it created.
    @Test("Chain-needed schemas stay offered after a tool result")
    @available(macOS 15.4, *)
    func chainSchemasSurviveToolResults() throws {
        let created = try ToolCall(
            id: "call-create",
            toolName: "workspace.createFile",
            argumentsJSON: Data(#"{"path":"test.txt","content":"hello"}"#.utf8),
            scope: .local
        )
        let build = LocalProviderAdapter.buildPrompt(
            for: Self.request(
                userText: "读取 test.txt 并告诉我内容",
                toolResults: [("call-create", "{\"status\":\"ok\",\"path\":\"test.txt\"}")],
                pendingToolCalls: [created]
            )
        )
        let selected = Set(build.selectedTools.map(\.name))
        #expect(selected.contains("workspace.createFile"))
        #expect(selected.contains("workspace.readFile"))
        // The receipt is rendered as evidence for the follow-up turn.
        let envelope = build.systemInstructions + "\n" + build.text
        #expect(envelope.contains("TOOL RESULT call-create"))
        #expect(build.systemInstructions.contains("workspace.readFile"))
    }

    /// Context/compaction limits are preserved: the base set is admitted
    /// inside the existing per-window schema budget, never on top of it.
    @Test("The base set respects the small-window schema budget")
    @available(macOS 15.4, *)
    func baseSetRespectsBudget() {
        for contextTokens in [2_048, 4_096, 8_192] {
            let build = LocalProviderAdapter.buildPrompt(
                for: Self.request(
                    userText: "创建一个文件并写入内容",
                    contextTokens: contextTokens
                )
            )
            let selected = build.selectedTools
            // Deterministic order keeps chat templates stable across turns.
            #expect(selected.map(\.name) == selected.map(\.name).sorted())
            #expect(!selected.isEmpty, "every window must still offer the file tools it can afford")
            #expect(selected.count <= 10, "never more than the widest inventory budget")
            #expect(!build.exceedsContextWindow)
            let selectedNames = Set(selected.map(\.name))
            // The critical create/write pair is always affordable, even in the
            // smallest supported window.
            #expect(selectedNames.contains("workspace.createFile"))
            #expect(selectedNames.contains("workspace.writeFile"))
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
