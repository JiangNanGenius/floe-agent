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
            // Discovery tools are admissible in fallback mode so weak models
            // can find names; the authoritative directory lists them first.
            #expect(local.systemInstructions.contains("AVAILABLE TOOL NAMES (authoritative): tools.list, tools.search, workspace.readFile"))
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
