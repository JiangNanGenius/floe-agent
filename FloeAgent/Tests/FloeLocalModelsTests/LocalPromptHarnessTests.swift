import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
import FloePersistence
import FloeSecurity
import FloeTools
@testable import FloeAgentRuntime
@testable import FloeLocalModels

private final class LocalPromptCapture: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIResponses
    private let lock = NSLock()
    private var captured: [ProviderStreamRequest] = []
    var requests: [ProviderStreamRequest] { lock.withLock { captured } }
    func stream(request: ProviderStreamRequest, credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
        lock.withLock { captured.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(.init(text: "Synthetic boundary captured.")))
            continuation.yield(.completed(.init(stopReason: .endTurn)))
            continuation.finish()
        }
    }
    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
}

private struct LocalPromptNoExecution: ToolExecutor {
    var allDescriptors: [ToolCatalog.Descriptor] {
        [.init(name: "workspace.readFile", toolDescription: "Read a workspace file", parametersJSON: "{}", riskLabels: [], isSideEffecting: false)]
    }
    func descriptor(named name: String) -> ToolCatalog.Descriptor? { allDescriptors.first { $0.name == name } }
    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        throw FloeError.validationFailed("Synthetic boundary test must not execute tools")
    }
}

@Suite("Local prompt through the run harness")
struct LocalPromptHarnessTests {
    @Test("Normal and prepared launches preserve runtime state through local adaptation")
    @available(macOS 15.4, *)
    func localServiceChoosesCompactContextBeforeProviderDispatch() async throws {
        for prepared in [false, true] {
            let database = try DatabaseManager.inMemory()
            try await database.migrate()
            let conversations = SQLiteConversationStore(database: database)
            let runs = SQLiteRunStore(database: database)
            let conversationID = UUID()
            try await conversations.saveConversation(.init(id: conversationID, title: "Synthetic local context", createdAt: Date(), updatedAt: Date()))
            let provider = LocalProviderAdapter.providerProfile
            let model = ModelProfile(providerID: provider.id, remoteModelID: "qwen3.5-4b-mlx4",
                displayName: "Synthetic local", limits: .init(contextTokens: 16_384, maxOutputTokens: 512), capabilities: [.text, .tools])
            let capture = LocalPromptCapture()
            let service = ConversationRunService(
                configuration: .init(conversationID: conversationID, provider: provider, model: model, allowedToolNames: ["workspace.readFile"]),
                adapter: capture, policy: HumanApprovalPolicy(), executor: LocalPromptNoExecution(),
                conversationStore: conversations, runStore: runs,
                runContext: .init(workspaceName: "Synthetic workspace", selectedRelativePath: "documents/source.md",
                                  executionTarget: "local", availableToolNames: ["workspace.readFile"], memoryContext: "Prior result: revision seven"))
            let user = "Read workspace file documents/source.md before review. " + String(repeating: "Review provided material. ", count: 60)
                + "Current correction: preserve all attachment positions."
                + String(repeating: " Continue the existing task. ", count: 60)
            if prepared {
                // This entry point consumes an already durable launch record.
                try await runs.saveRun(.init(id: service.runID, conversationID: conversationID, state: "preparing", goal: user, startedAt: Date(), conversationMode: "chat"))
                try await service.startPrepared(goal: user)
            } else {
                try await service.start(goal: user)
            }
            let request = try #require(capture.requests.first)
            #expect(request.toolSchemas.contains { $0.name == "workspace.readFile" })
            // Match LocalProviderAdapter.stream's dispatch-time clock refresh
            // without loading weights or invoking a real model in this test.
            let local = LocalProviderAdapter.buildPrompt(for: request.refreshingRuntimeClock())
            #expect(local.systemInstructions.contains("Floe local runtime contract"))
            #expect(!local.systemInstructions.contains("# Operating protocol"))
            #expect(local.systemInstructions.contains("Synthetic workspace"))
            #expect(local.systemInstructions.contains("documents/source.md"))
            #expect(local.systemInstructions.contains("Prior result: revision seven"))
            #expect(local.systemInstructions.contains("Current runtime time:"))
            #expect(local.systemInstructions.contains("Runtime clock at dispatch:"))
            // Discovery/paging metadata helpers are admissible in fallback
            // mode so weak models can find names and page retained results;
            // the authoritative directory is exactly this run's supplied set.
            #expect(local.systemInstructions.contains("AVAILABLE TOOL NAMES (authoritative): tools.list, tools.readResult, tools.search, workspace.readFile"))
            #expect(local.text.contains(user))
            #expect(!local.text.contains("Prior result: revision seven"))
            if let path = ProcessInfo.processInfo.environment["FLOE_SYNTHETIC_LOCAL_PROMPT_AUDIT_DIR"] {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let snapshot: [String: Any] = ["synthetic": true, "realModelInvoked": false,
                    "launch": prepared ? "prepared" : "normal", "systemInstructions": local.systemInstructions,
                    "userTranscript": local.text, "toolNames": local.selectedTools.map(\.name),
                    "systemCharacters": local.systemInstructions.count, "transcriptCharacters": local.text.count]
                try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent(prepared ? "local-prepared.json" : "local-normal.json"), options: .atomic)
            }
        }
    }
}

// MARK: - Replayed tool evidence for on-device models

@Suite("Local replayed tool evidence")
struct LocalReplayedToolEvidenceTests {
    @available(macOS 15.4, iOS 26.0, *)
    private func request(
        replayedPairs: [ReplayedToolPair],
        systemEnvelope: String = "Run context: synthetic workspace. Current runtime time: fixed."
    ) throws -> ProviderStreamRequest {
        let provider = LocalProviderAdapter.providerProfile
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "qwen3.8-4b-heretic-mlx4",
            displayName: "Synthetic local",
            limits: .init(contextTokens: 16_384, maxOutputTokens: 512),
            capabilities: [.text, .tools]
        )
        return ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: [
                (role: "system", content: systemEnvelope),
                (role: "user", content: "Continue the review.")
            ],
            replayedToolPairs: replayedPairs,
            toolSchemas: [ToolSchemaDescriptor(
                name: "workspace.readFile",
                description: "Read a workspace file",
                parametersJSON: #"{"type":"object"}"#
            )],
            allToolNames: ["workspace.readFile"]
        ).refreshingRuntimeClock()
    }

    @Test("Settled tool pairs from earlier turns are replayed to a local model")
    @available(macOS 15.4, *)
    func settledPairsAreReplayed() throws {
        let call = try ToolCall(
            id: "call-42",
            toolName: "workspace.readFile",
            argumentsJSON: Data(#"{"path":"notes.md"}"#.utf8),
            scope: .local
        )
        let result = ToolResult(
            callID: "call-42",
            status: .ok,
            outputSummary: "Revision seven preserved all attachment positions.",
            outputDigest: "digest"
        )
        let local = LocalProviderAdapter.buildPrompt(for: try request(
            replayedPairs: [ReplayedToolPair(call: call, result: result)]
        ))
        #expect(local.text.contains("EARLIER COMPLETED TOOL WORK"))
        #expect(local.text.contains("workspace.readFile"))
        #expect(local.text.contains("call-42"))
        #expect(local.text.contains("Revision seven preserved"))
    }

    @Test("No replay section is rendered without settled pairs")
    @available(macOS 15.4, *)
    func noReplayWithoutPairs() throws {
        let local = LocalProviderAdapter.buildPrompt(for: try request(replayedPairs: []))
        #expect(!local.text.contains("EARLIER COMPLETED TOOL WORK"))
    }

    @Test("The repair prompt keeps bounded referential context instead of the whole transcript")
    @available(macOS 15.4, *)
    func repairPromptKeepsReferentialContext() throws {
        let settledCall = try ToolCall(
            id: "call-7",
            toolName: "workspace.readFile",
            argumentsJSON: Data(#"{"path":"exports/summary.md"}"#.utf8),
            scope: .local
        )
        let settled = ReplayedToolPair(
            call: settledCall,
            result: ToolResult(
                callID: "call-7",
                status: .ok,
                outputSummary: "Read exports/summary.md: 12 sections ready for export.",
                outputDigest: "digest"
            )
        )
        var request = try request(replayedPairs: [settled])
        // An early bulk turn that must never enter the repair prefill, with
        // enough later turns that it falls outside the bounded recent window.
        request.messages.insert(
            (role: "user", content: "BULK-MARKER " + String(repeating: "old transcript ", count: 400)),
            at: 1
        )
        request.messages.append((role: "user", content: "先总结一下这份文件"))
        request.messages.append((role: "assistant", content: "我已经读完了 exports/summary.md，可以导出。"))
        request.messages.append((role: "user", content: "继续，把它导出为 PDF"))
        let prompt = LocalProviderAdapter.repairPrompt(
            for: request,
            directive: "REPAIR-DIRECTIVE"
        )
        // Referents survive: the settled file, the assistant's last turn, the
        // current continuation request and the call IDs.
        #expect(prompt.contains("exports/summary.md"))
        #expect(prompt.contains("call-7"))
        #expect(prompt.contains("继续，把它导出为 PDF"))
        #expect(prompt.contains("我已经读完了"))
        #expect(prompt.contains("REPAIR-DIRECTIVE"))
        // Old bulk transcript stays out of the second prefill.
        #expect(!prompt.contains("BULK-MARKER"))
        #expect(prompt.count < 8_000)
    }

    @Test("The replay projection stays bounded and keeps the newest pairs")
    @available(macOS 15.4, *)
    func replayProjectionIsBounded() throws {
        var pairs: [ReplayedToolPair] = []
        for index in 0..<40 {
            let call = try ToolCall(
                id: "call-\(index)",
                toolName: "workspace.readFile",
                argumentsJSON: Data("{\"path\":\"file-\(index).md\"}".utf8),
                scope: .local
            )
            pairs.append(ReplayedToolPair(
                call: call,
                result: ToolResult(
                    callID: call.id,
                    status: .ok,
                    outputSummary: String(repeating: "evidence-\(index) ", count: 200),
                    outputDigest: "digest"
                )
            ))
        }
        let local = LocalProviderAdapter.buildPrompt(for: try request(replayedPairs: pairs))
        let section = local.text.components(separatedBy: "EARLIER COMPLETED TOOL WORK").last ?? ""
        #expect(section.count <= 2_400)
        #expect(section.contains("call-39"))
        #expect(!section.contains("EARLIER TOOL CALL workspace.readFile id=call-0 "))
    }

    @Test("The on-device runtime envelope is preserved verbatim, never silently clipped")
    @available(macOS 15.4, *)
    func runtimeEnvelopeIsPreserved() throws {
        // Build 222 supersedes the intermediate head/tail clipping: the
        // harness envelope carries the memory context, the live clock and
        // auxiliary request instructions, and `LocalModelCatalogTests`
        // (`localPromptIsBounded`) pins the same no-silent-discard contract for
        // the complete envelope. A envelope that cannot fit the advertised
        // window is refused through `exceedsContextWindow` instead of being
        // rewritten into a prompt the harness never composed.
        let envelope = "HEAD-MARKER " + String(repeating: "context line ", count: 4_000) + " TAIL-MARKER"
        let local = LocalProviderAdapter.buildPrompt(for: try request(
            replayedPairs: [],
            systemEnvelope: envelope
        ))
        #expect(local.systemInstructions.contains(envelope))
        #expect(local.systemInstructions.contains("HEAD-MARKER"))
        #expect(local.systemInstructions.contains("TAIL-MARKER"))
        // The transcript stays bounded independently of the envelope.
        #expect(local.text.contains("Continue the review."))
    }
}

// MARK: - Cross-task history tools on-device admission

@Suite("Local authorized history tool admission")
struct LocalHistoryAdmissionTests {
    @Test("MLX receives the authorized conversation and shell tools; Apple keeps its native channel")
    @available(macOS 15.4, *)
    func conversationToolsFollowRuntimeAuthority() {
        let names: Set<String> = ["conversation.search", "conversation.read", "conversation.list", "workspace.readFile", "ssh.execute"]
        let mlx = LocalProviderAdapter.admissibleToolNames(from: names, modelRemoteID: "qwen3.8-4b-heretic-mlx4")
        // The runtime already applied the task ceiling. The adapter forwards
        // exactly that authorized set: cross-task history is no longer hidden
        // by a second curated local fence.
        #expect(mlx == names)
        let apple = LocalProviderAdapter.admissibleToolNames(from: names, modelRemoteID: AppleFoundationModelIdentity.remoteModelID)
        // The real Apple native-channel restriction still applies: no
        // non-Apple name is offered to Foundation Models.
        #expect(apple.isEmpty)
        #expect(apple.isDisjoint(with: names))
    }

    @Test("Notes and mail tools reach MLX; the Apple native channel stays Apple-only")
    @available(macOS 15.4, *)
    func notesToolsFollowRuntimeAuthority() throws {
        let names: Set<String> = [
            "notes.read", "notes.search", "notes.edit",
            "notes.attachFile", "notes.stageAttachment", "mail.send"
        ]
        let mlx = LocalProviderAdapter.admissibleToolNames(from: names, modelRemoteID: "qwen3.8-4b-heretic-mlx4")
        // Authorized document-assistant and mail surfaces are forwarded rather
        // than hidden by the adapter.
        #expect(mlx == names)
        let apple = LocalProviderAdapter.admissibleToolNames(from: names, modelRemoteID: AppleFoundationModelIdentity.remoteModelID)
        #expect(apple.isEmpty)
        // Not supplied means not callable: the parser still enforces the real
        // offered set rather than accepting any canonical name.
        let unauthorized = try LocalProviderAdapter.toolCall(
            from: #"{"tool_call":{"name":"notes.edit","arguments":{}}}"#,
            offeredToolNames: ["notes.read"]
        )
        #expect(unauthorized == nil)
    }

    @Test("Chinese and English history intents select the conversation pair")
    @available(macOS 15.4, *)
    func historyIntentSelectsConversationTools() throws {
        let provider = LocalProviderAdapter.providerProfile
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "qwen3.8-4b-heretic-mlx4",
            displayName: "Synthetic local",
            limits: .init(contextTokens: 16_384, maxOutputTokens: 512),
            capabilities: [.text, .tools]
        )
        let schemas = [
            ToolSchemaDescriptor(name: "conversation.search", description: "Search other Floe tasks", parametersJSON: #"{"type":"object"}"#),
            ToolSchemaDescriptor(name: "conversation.read", description: "Read a page from another Floe task", parametersJSON: #"{"type":"object"}"#),
            ToolSchemaDescriptor(name: "workspace.readFile", description: "Read a workspace file", parametersJSON: #"{"type":"object"}"#)
        ]
        let historyCases = ["之前任务里是怎么配置的", "what did we decide in the earlier chat history"]
        for userText in historyCases {
            let request = ProviderStreamRequest(
                provider: provider,
                model: model,
                messages: [
                    (role: "system", content: "Run context: synthetic workspace."),
                    (role: "user", content: userText)
                ],
                replayedToolPairs: [],
                toolSchemas: schemas,
                allToolNames: ["conversation.search", "conversation.read", "workspace.readFile"]
            ).refreshingRuntimeClock()
            let local = LocalProviderAdapter.buildPrompt(for: request)
            // An explicit history intent selects the authorized conversation
            // schemas; nothing in the adapter hides them. Selection alone does
            // not force a call on an informational question.
            let selected = Set(local.selectedTools.map(\.name))
            #expect(selected.contains("conversation.search"), "user text: \(userText)")
            #expect(selected.contains("conversation.read"), "user text: \(userText)")
            #expect(local.fallbackTools.contains { $0.name == "workspace.readFile" })
            #expect(!local.requiresToolCall, "user text: \(userText)")
        }
        // An explicit news-search turn with NO configured web.search gets
        // the truthful notice and zero tools instead of a substituted call.
        let searchRequest = ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: [
                (role: "system", content: "Run context: synthetic workspace."),
                (role: "user", content: "搜索一下今天的新闻")
            ],
            toolSchemas: schemas,
            allToolNames: ["conversation.search", "conversation.read", "workspace.readFile"]
        ).refreshingRuntimeClock()
        let searchLocal = LocalProviderAdapter.buildPrompt(for: searchRequest)
        #expect(searchLocal.selectedTools.isEmpty)
        #expect(searchLocal.systemInstructions.contains("WEB SEARCH UNAVAILABLE FOR THIS REQUEST"))
        #expect(!searchLocal.requiresToolCall)
    }
}


// MARK: - Mixed-script prompt pressure

@Suite("Local prompt token pressure")
struct LocalPromptPressureTests {
    @Test("The mixed-script estimate charges CJK per scalar and ASCII per bytes")
    func mixedScriptEstimates() {
        #expect(LocalPromptPressure.heuristicTokens(in: "") == 0)
        #expect(LocalPromptPressure.heuristicTokens(in: "你好世界") >= 4)
        #expect(LocalPromptPressure.heuristicTokens(in: "hello world") >= 2)
        // A 12-character CJK string must never be estimated like 12 ASCII
        // bytes; that mismatch was the character-vs-token budget gap.
        #expect(LocalPromptPressure.heuristicTokens(in: "历史记录条目一二三四五六")
            > LocalPromptPressure.heuristicTokens(in: "history items"))
    }

    @Test("Token clipping keeps head and tail and is idempotent")
    func tokenClipping() {
        let text = String(repeating: "开头标记。", count: 400)
            + String(repeating: "结尾标记。", count: 400)
        let clipped = LocalPromptPressure.clippedToTokens(text, limit: 160)
        #expect(LocalPromptPressure.heuristicTokens(in: clipped) <= 160)
        #expect(clipped.contains("开头标记"))
        #expect(clipped.contains("结尾标记"))
        #expect(LocalPromptPressure.clippedToTokens(clipped, limit: 160) == clipped)
        #expect(LocalPromptPressure.clippedToTokens("短文本", limit: 160) == "短文本")
    }

    @Test("A CJK-heavy 8K local prompt stays inside the window and keeps the current request")
    @available(macOS 15.4, iOS 26.0, *)
    func cjkHeavyPromptFitsEightKWindow() throws {
        let provider = LocalProviderAdapter.providerProfile
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "qwen3.8-4b-heretic-mlx4",
            displayName: "Synthetic local",
            limits: .init(contextTokens: 8_192, maxOutputTokens: 1_024),
            capabilities: [.text, .tools]
        )
        var history: [(role: String, content: String)] = []
        for index in 0..<30 {
            let role = index.isMultiple(of: 2) ? "user" : "assistant"
            history.append((
                role: role,
                content: "历史记录条目\(index)：" + String(
                    repeating: "这段中文内容用于验证字符预算不等于模型实际token预算。",
                    count: 6
                )
            ))
        }
        let current = "查一下之前任务里关于构建 204 的记录，并把结论总结出来。"
        history.append((role: "user", content: current))
        let schemas = [
            ToolSchemaDescriptor(name: "conversation.search", description: "Search other Floe tasks", parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}}}"#),
            ToolSchemaDescriptor(name: "conversation.read", description: "Read a page from another Floe task", parametersJSON: #"{"type":"object","properties":{"conversationID":{"type":"string"}}}"#),
            ToolSchemaDescriptor(name: "workspace.readFile", description: "Read a workspace file", parametersJSON: #"{"type":"object"}"#),
            ToolSchemaDescriptor(name: "web.search", description: "Search the web", parametersJSON: #"{"type":"object"}"#)
        ]
        let request = ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: history,
            toolSchemas: schemas,
            allToolNames: schemas.map(\.name)
        ).refreshingRuntimeClock()

        let local = LocalProviderAdapter.buildPrompt(for: request)

        #expect(!local.exceedsContextWindow)
        #expect(local.estimatedPromptTokens <= local.windowPromptTokenBudget)
        #expect(local.windowPromptTokenBudget == 8_192 - 1_024)
        // The current request is protected: CJK clipping must never cut the
        // correction the user just typed.
        #expect(local.text.contains(current))
        #expect(local.selectedTools.contains { $0.name == "web.search" })
    }

    @Test("An oversized current request is refused before any model allocation")
    @available(macOS 15.4, iOS 26.0, *)
    func oversizedCurrentRequestRefused() throws {
        let provider = LocalProviderAdapter.providerProfile
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "qwen3.8-4b-heretic-mlx4",
            displayName: "Synthetic local",
            limits: .init(contextTokens: 8_192, maxOutputTokens: 1_024),
            capabilities: [.text, .tools]
        )
        let oversized = String(repeating: "这是一条超过本地模型窗口的当前请求。", count: 1_200)
        let request = ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: [(role: "user", content: oversized)],
            toolSchemas: [],
            allToolNames: []
        ).refreshingRuntimeClock()

        let local = LocalProviderAdapter.buildPrompt(for: request)

        #expect(local.exceedsContextWindow)
        #expect(local.estimatedPromptTokens > local.windowPromptTokenBudget)
    }

    @Test("A tiny window smaller than the section floors is refused by the final guard")
    @available(macOS 15.4, iOS 26.0, *)
    func tinyWindowIsRefusedByFinalGuard() throws {
        // The per-section floors can exceed a small window on their own; the
        // final window check is the boundary that still refuses before any
        // model or KV allocation.
        let budgets = LocalPromptPressure.sectionTokenBudgets(
            contextTokens: 512,
            outputReserveTokens: 256,
            nativeSchemaTokens: 0
        )
        let floors = budgets.directory + budgets.offeredTools
            + budgets.runtimeInstructions + budgets.transcript
            + budgets.evidence + budgets.replay
        #expect(floors > 512 - 256)

        let provider = LocalProviderAdapter.providerProfile
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "qwen3.8-4b-heretic-mlx4",
            displayName: "Synthetic local",
            limits: .init(contextTokens: 512, maxOutputTokens: 256),
            capabilities: [.text, .tools]
        )
        let request = ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: [
                (role: "system", content: "Tiny window runtime context."),
                (role: "user", content: String(repeating: "继续回答这个很小窗口的问题。", count: 60))
            ],
            toolSchemas: [],
            allToolNames: []
        ).refreshingRuntimeClock()

        let local = LocalProviderAdapter.buildPrompt(for: request)

        #expect(local.exceedsContextWindow)
        #expect(local.estimatedPromptTokens > local.windowPromptTokenBudget)
    }

    @Test("A clipped CJK receipt keeps its id and conversation cursor metadata")
    @available(macOS 15.4, iOS 26.0, *)
    func cjkReceiptKeepsMetadataOnSmallWindow() throws {
        let provider = LocalProviderAdapter.providerProfile
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "qwen3.8-4b-heretic-mlx4",
            displayName: "Synthetic local",
            limits: .init(contextTokens: 2_048, maxOutputTokens: 256),
            capabilities: [.text, .tools]
        )
        let call = try ToolCall(
            id: "receipt-cjk",
            toolName: "conversation.read",
            argumentsJSON: Data(#"{"conversationID":"11111111-1111-1111-1111-111111111111"}"#.utf8),
            scope: .local
        )
        let metadata = "status=ok conversationID=11111111-1111-1111-1111-111111111111 "
            + "cursor=opaque-cursor-42 hasMore=true sources=[22222222-2222-2222-2222-222222222222] "
        let output = metadata + String(
            repeating: "这是一页很长的中文历史记录内容，用于验证小窗口下回执不会被整条丢弃。",
            count: 120
        )
        let request = ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: [(role: "user", content: "读取之前任务的记录并总结")],
            toolResults: [(callID: call.id, output: output)],
            pendingToolCalls: [call],
            toolSchemas: [ToolSchemaDescriptor(
                name: "conversation.read",
                description: "Read a page from another Floe task",
                parametersJSON: #"{"type":"object"}"#
            )],
            allToolNames: ["conversation.read"]
        ).refreshingRuntimeClock()

        let local = LocalProviderAdapter.buildPrompt(for: request)

        // The receipt is clipped by tokens but never dropped whole: the callID
        // header and the head-anchored conversation metadata stay visible.
        #expect(local.text.contains("TOOL RESULT receipt-cjk"))
        #expect(local.text.contains("conversationID=11111111-1111-1111-1111-111111111111"))
        #expect(local.text.contains("cursor=opaque-cursor-42"))
        #expect(local.text.contains("sources=[22222222-2222-2222-2222-222222222222]"))
        #expect(!local.exceedsContextWindow)
    }
}


// MARK: - Complete local tool contracts under the actual window

@Suite("Local complete-contract sizing")
struct LocalCompleteContractSizingTests {
    private static let cadPayloadVocabulary = "material list|read|create|update|apply|applyFaces; parameters list|update|updateSketchEntity|setSketchDimension|feature.suppress|feature.delete; animation list|query|evaluate|createClip|updateClip|deleteClip|addTrack|setKeyframe|setCameraKeyframe|setPartKeyframe|capture|export"

    private static func cadDescriptor(detail: String = String(repeating: "Authoring example. ", count: 60)) throws -> ToolSchemaDescriptor {
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["action"],
            "description": "Complete CAD authoring contract. \(detail)",
            "properties": [
                "action": [
                    "type": "string",
                    "enum": ["capabilities", "read", "query", "parameters", "material", "animation"]
                ],
                "path": ["type": "string", "maxLength": 1024],
                "payload": [
                    "type": "string",
                    "description": Self.cadPayloadVocabulary + " " + detail
                ],
                "zz_last_field": [
                    "type": "string",
                    "description": "SENTINEL_LAST_FIELD"
                ]
            ]
        ]
        let raw = String(
            decoding: try JSONSerialization.data(withJSONObject: schema),
            as: UTF8.self
        )
        return ToolSchemaDescriptor(
            name: "cad.document",
            description: "Inspect and edit native CAD documents, including material, parameter and animation payloads.",
            parametersJSON: raw
        )
    }

    private static func model(_ id: String, _ contextTokens: Int, _ outputTokens: Int = 1_024) -> ModelProfile {
        ModelProfile(
            providerID: LocalProviderAdapter.providerProfile.id,
            remoteModelID: id,
            displayName: "Synthetic local",
            limits: .init(contextTokens: contextTokens, maxOutputTokens: outputTokens),
            capabilities: [.text, .tools]
        )
    }

    @Test("A large window keeps complete CAD contracts and the result tail")
    @available(macOS 15.4, *)
    func largeWindowKeepsCompleteContractsAndResultTail() throws {
        let cad = try Self.cadDescriptor()
        let read = ToolSchemaDescriptor(
            name: "workspace.readFile",
            description: "Read a workspace file",
            parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#
        )
        let call = try ToolCall(
            id: "cad-read-1",
            toolName: "workspace.readFile",
            argumentsJSON: Data(#"{"path":"toycar.floecad"}"#.utf8),
            scope: .local
        )
        let output = String(repeating: "verified evidence line ", count: 300)
            + "RESULT_TAIL_SENTINEL"
        let request = ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: Self.model("qwen3.8-4b-heretic-mlx4", 32_768),
            messages: [("user", "打开 toycar.floecad，修改支架孔径并检查动画关键帧")],
            toolResults: [(callID: call.id, output: output)],
            pendingToolCalls: [call],
            toolSchemas: [cad, read],
            allToolNames: [cad.name, read.name]
        )
        let build = LocalProviderAdapter.buildPrompt(for: request)
        let selectedCAD = try #require(build.selectedTools.first { $0.name == "cad.document" })
        #expect(selectedCAD.parametersJSON == cad.parametersJSON)
        #expect(build.systemInstructions.contains(cad.parametersJSON))
        #expect(build.systemInstructions.contains(Self.cadPayloadVocabulary))
        #expect(build.systemInstructions.contains("SENTINEL_LAST_FIELD"))
        #expect(build.systemInstructions.contains("CAD TOOL ARGUMENTS (cad.document)"))
        #expect(build.nativeToolSchemas.isEmpty)
        #expect(build.text.contains("TOOL RESULT \(call.id)"))
        #expect(build.text.contains("RESULT_TAIL_SENTINEL"))
        #expect(!build.text.contains("[omitted]"))
        #expect(!build.systemInstructions.contains("SCHEMA BUDGET"))
        #expect(build.estimatedPromptTokens <= build.windowPromptTokenBudget)
        #expect(!build.exceedsContextWindow)

        // Native-schema path: the same complete bytes reach the chat template.
        let native = LocalProviderAdapter.buildPrompt(for: ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: Self.model("gemma4-e4b-mlx4", 32_768),
            messages: [("user", "打开 toycar.floecad，修改支架孔径并检查动画关键帧")],
            toolResults: [(callID: call.id, output: output)],
            pendingToolCalls: [call],
            toolSchemas: [cad, read],
            allToolNames: [cad.name, read.name]
        ))
        let nativeCAD = try #require(native.nativeToolSchemas.first { $0.name == "cad.document" })
        #expect(nativeCAD.parametersJSON == cad.parametersJSON)
        #expect(nativeCAD.description == cad.description)
        #expect(native.text.contains("RESULT_TAIL_SENTINEL"))
        #expect(native.estimatedPromptTokens <= native.windowPromptTokenBudget)
        #expect(!native.exceedsContextWindow)
    }

    @Test("A small window defers a whole definition without slicing it")
    @available(macOS 15.4, *)
    func smallWindowDefersWholeDefinition() throws {
        let huge = String(repeating: "X", count: 20_000)
        let cad = try Self.cadDescriptor(detail: huge)
        let read = ToolSchemaDescriptor(
            name: "workspace.readFile",
            description: "Read a workspace file",
            parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}}}"#
        )
        let toolSearch = ToolSchemaDescriptor(
            name: "tools.search",
            description: "Load one exact tool definition",
            parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}}}"#
        )
        let build = LocalProviderAdapter.buildPrompt(for: ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: Self.model("qwen3.8-4b-heretic-mlx4", 4_096, 512),
            messages: [("user", "修改支架的孔径为 8 毫米并增加圆角")],
            toolSchemas: [toolSearch, cad, read],
            allToolNames: [toolSearch.name, cad.name, read.name]
        ))
        #expect(!build.selectedTools.contains { $0.name == "cad.document" })
        #expect(build.fallbackTools.contains { $0.name == "cad.document" })
        #expect(build.selectedTools.contains { $0.name == "tools.search" })
        #expect(build.systemInstructions.contains("SCHEMA BUDGET"))
        #expect(build.systemInstructions.contains("deferred rather than sliced"))
        #expect(build.systemInstructions.contains("Load one exact name with tools.search"))
        #expect(build.systemInstructions.contains("did not fit this model window"))
        #expect(!build.systemInstructions.contains("SENTINEL_LAST_FIELD"))
        #expect(!build.systemInstructions.contains(String(repeating: "X", count: 200)))
        #expect(!build.selectedTools.contains { $0.parametersJSON.contains("XXXXX") })
        #expect(!build.requiresToolCall)
        #expect(build.estimatedPromptTokens <= build.windowPromptTokenBudget)
        #expect(!build.exceedsContextWindow)
    }

    @Test("A complete pending result is not clipped a second time when it fits")
    @available(macOS 15.4, *)
    func completePendingResultIsNotReclipped() throws {
        let read = ToolSchemaDescriptor(
            name: "workspace.readFile",
            description: "Read a workspace file",
            parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}}}"#
        )
        let call = try ToolCall(
            id: "receipt-full",
            toolName: "workspace.readFile",
            argumentsJSON: Data(#"{"path":"report.txt"}"#.utf8),
            scope: .local
        )
        let output = "HEAD_SENTINEL\n"
            + String(repeating: "complete result body line\n", count: 120)
            + "TAIL_SENTINEL"
        let build = LocalProviderAdapter.buildPrompt(for: ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: Self.model("qwen3.8-4b-heretic-mlx4", 16_384),
            messages: [("user", "读取 report.txt 并总结")],
            toolResults: [(callID: call.id, output: output)],
            pendingToolCalls: [call],
            toolSchemas: [read],
            allToolNames: [read.name]
        ))
        #expect(build.text.contains("HEAD_SENTINEL"))
        #expect(build.text.contains("TAIL_SENTINEL"))
        #expect(build.text.contains(output))
        #expect(!build.text.contains("[omitted]"))
        #expect(build.estimatedPromptTokens <= build.windowPromptTokenBudget)
        #expect(!build.exceedsContextWindow)
    }

    @Test("An over-budget pending result keeps its capture ref and marker")
    @available(macOS 15.4, *)
    func overBudgetPendingResultKeepsCaptureRef() throws {
        let read = ToolSchemaDescriptor(
            name: "workspace.readFile",
            description: "Read a workspace file",
            parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}}}"#
        )
        let call = try ToolCall(
            id: "receipt-large",
            toolName: "workspace.readFile",
            argumentsJSON: Data(#"{"path":"large.txt"}"#.utf8),
            scope: .local
        )
        let output = "status=ok ref=tr_ABC123\n"
            + String(repeating: "这是一段完整保留但超出当前窗口的结果内容。", count: 160)
            + "TAIL_SENTINEL"
        let build = LocalProviderAdapter.buildPrompt(for: ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: Self.model("qwen3.8-4b-heretic-mlx4", 2_048, 256),
            messages: [("user", "读取 large.txt")],
            toolResults: [(callID: call.id, output: output)],
            pendingToolCalls: [call],
            toolSchemas: [read],
            allToolNames: [read.name]
        ))
        #expect(build.text.contains("TOOL RESULT \(call.id)"))
        #expect(build.text.contains("tr_ABC123"))
        #expect(build.text.contains("[omitted]") || build.text.contains("omitted"))
        #expect(build.text.contains("tools.readResult"))
        #expect(build.estimatedPromptTokens <= build.windowPromptTokenBudget)
        #expect(!build.exceedsContextWindow)
    }

    @Test("Apple and Qwen protocol guards remain after schema sizing")
    @available(macOS 15.4, *)
    func protocolGuardsRemain() throws {
        let cad = try Self.cadDescriptor()
        let qwen = LocalProviderAdapter.buildPrompt(for: ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: Self.model("qwen3.8-4b-heretic-mlx4", 16_384),
            messages: [("user", "检查 CAD 文档")],
            toolSchemas: [cad],
            allToolNames: [cad.name]
        ))
        #expect(qwen.nativeToolSchemas.isEmpty)
        #expect(qwen.systemInstructions.contains(
            "the chat template receives no native tool schemas"
        ))
        #expect(!qwen.systemInstructions.lowercased().contains(
            "use the native tool interface"
        ))

        let apple = LocalProviderAdapter.buildPrompt(for: ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: Self.model(AppleFoundationModelIdentity.remoteModelID, 8_192),
            messages: [("user", "我的当前位置是哪里？")],
            toolSchemas: [
                ToolSchemaDescriptor(name: "apple.location.current", description: "Get current location"),
                ToolSchemaDescriptor(name: "apple.automation.list", description: "List automations"),
                cad
            ]
        ))
        #expect(apple.selectedTools.map(\.name) == ["apple.location.current"])
        #expect(apple.nativeToolSchemas.isEmpty)
        #expect(apple.fallbackTools.map(\.name).sorted()
            == ["apple.automation.list", "apple.location.current"])
        #expect(apple.requiresToolCall)
    }

    @Test("Minimal repair carries the whole schema only when its actual window fits")
    @available(macOS 15.4, *)
    func minimalRepairUsesActualWindow() throws {
        let padding = String(repeating: "a", count: 3_000)
        let raw = #"{"type":"object","properties":{"q":{"type":"string","description":"__PADDING__"}},"required":["q"]}"#
            .replacingOccurrences(of: "__PADDING__", with: padding)
        let tool = ToolSchemaDescriptor(
            name: "web.search",
            description: "Search the web",
            parametersJSON: raw
        )
        let instructions = try #require(LocalProviderAdapter.PromptBuild.minimalRepairInstructions(
            tool: tool,
            usesNativeToolSchemas: false,
            extraSafety: "Keep workspace scope."
        ))
        // The old 2 400-character schema / 8 192-character instruction caps
        // are gone; the complete schema is present and the actual repair
        // window is the only fit decision.
        #expect(instructions.contains(raw))
        #expect(!instructions.contains("...[omitted]"))
        #expect(instructions.contains("Required: q"))
        #expect(!instructions.lowercased().contains("use the native tool interface"))
        #expect(LocalProviderAdapter.PromptBuild.repairFitsContext(
            instructions: instructions, prompt: "搜索今天的新闻",
            tool: tool, usesNativeToolSchemas: false,
            contextTokens: 16_384
        ))
        #expect(!LocalProviderAdapter.PromptBuild.repairFitsContext(
            instructions: instructions, prompt: "搜索今天的新闻",
            tool: tool, usesNativeToolSchemas: false,
            contextTokens: 1_024
        ))

        // The native channel renders the schema a second time; the same whole
        // contract still fits a large window and never uses the JSON claim.
        let nativeInstructions = try #require(LocalProviderAdapter.PromptBuild.minimalRepairInstructions(
            tool: tool,
            usesNativeToolSchemas: true,
            extraSafety: "Keep workspace scope."
        ))
        #expect(nativeInstructions.contains(raw))
        #expect(nativeInstructions.contains("native tool interface"))
        #expect(LocalProviderAdapter.PromptBuild.repairFitsContext(
            instructions: nativeInstructions, prompt: "search",
            tool: tool, usesNativeToolSchemas: true,
            contextTokens: 16_384
        ))

        // A long authoritative envelope that does not fit the actual window
        // is skipped explicitly; its complete text is never clipped.
        let hugeRules = String(repeating: "Preserve user data. ", count: 5_000)
        let tooLarge = try #require(LocalProviderAdapter.PromptBuild.minimalRepairInstructions(
            tool: tool,
            usesNativeToolSchemas: false,
            extraSafety: hugeRules
        ))
        #expect(tooLarge.contains(hugeRules.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(!LocalProviderAdapter.PromptBuild.repairFitsContext(
            instructions: tooLarge, prompt: "搜索",
            tool: tool, usesNativeToolSchemas: false,
            contextTokens: 8_192
        ))

        // A malformed schema still fails closed without a repair attempt.
        #expect(LocalProviderAdapter.PromptBuild.minimalRepairInstructions(
            tool: ToolSchemaDescriptor(
                name: "web.search", description: "x", parametersJSON: "not json"
            ),
            usesNativeToolSchemas: false,
            extraSafety: ""
        ) == nil)
    }
}

// MARK: - Decode-rate provenance (PiP speed口径)

@Suite("Local decode-rate accounting")
struct LocalDecodeRateTests {
    @Test func weightedDecodeRateIgnoresPrefillAndWeightsByTokens() {
        // 40 tok/s over 10 tokens + 20 tok/s over 30 tokens → 25 tok/s.
        let rate = DecodeRateCombiner.weightedDecodeRate(
            main: (rate: 40, outputTokens: 10),
            repair: (rate: 20, outputTokens: 30)
        )
        #expect(rate == 25)
    }

    @Test func weightedDecodeRateSurvivesMissingLegs() {
        #expect(DecodeRateCombiner.weightedDecodeRate(main: (nil, 10), repair: (30, 5)) == 30)
        #expect(DecodeRateCombiner.weightedDecodeRate(main: (nil, 0), repair: (nil, 0)) == nil)
    }
}
