import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
@testable import FloeAgentRuntime
@testable import FloeLocalModels

/// Build229 end-to-end budget regression: on the physical device a
/// 12-character greeting reached a 12,296-character source prompt
/// (systemCharacters 15,276, estimatedPromptTokens 6,196, real prepared
/// tokens 5,314) because the runtime envelope carried an ~11 KB project
/// instruction file plus memory/style/profile state verbatim. These tests
/// run the *bounded* runtime envelope through the production
/// `LocalProviderAdapter.buildPrompt` and pin the resulting prompt size,
/// the stable base file-tool set, and two consecutive tool turns with real
/// receipts.
@Suite("Local first-chat budget (Build229)")
struct LocalFirstChatBudgetTests {
    /// Same device-scale content as LocalEnvelopeBoundsTests: an ~11 KB
    /// project instruction file plus memory, style, profile, links and a
    /// listing.
    private static func deviceScaleContext() -> ConversationRunService.RunContext {
        let instructions = "# Workspace instructions (FLOE.md/AGENTS.md)\n" + String(repeating: """
        ## Repository section
        - Trace the actual UI → service → runtime/storage path before fixing symptoms.
        - Preserve pinned revisions and hashes; check availability against the SDK.
        - Notes storage survives deletion of a chat task; keep iPad-first layouts.

        """, count: 26)
        return .init(
            workspaceName: "IOS AI AGENT",
            selectedRelativePath: "FloeAgent/Sources/FloeLocalModels/LocalProviderAdapter.swift",
            executionTarget: "local",
            availableToolNames: ["workspace.readFile", "workspace.listDirectory", "tools.list", "tools.search"],
            skillInstructions: "# Workflow guide\nUse the narrowest authoritative read; batch independent calls.",
            memoryContext: String(repeating: "Prior session: verified Build228 two-turn tool receipts on the same workspace. ", count: 8),
            soulContext: String(repeating: "Be concise, warm and precise; answer in the user's language. ", count: 6),
            userProfileContext: String(repeating: "User prefers bilingual concise updates and evidence-backed claims. ", count: 6),
            workspaceNotes: ["cloud-link: official-service via verified tunnel"],
            workspaceListing: "FloeAgent/\ndocs\nLocal\nREADME.md\nAGENTS.md\n",
            projectInstructions: instructions
        )
    }

    @available(macOS 15.4, iOS 26.0, *)
    private static func boundedEnvelope(contextTokens: Int = 8_192) -> String {
        ConversationRunService.buildContextMessage(
            deviceScaleContext(), mode: .chat, toolsAvailable: true, compactForLocal: true,
            localContextTokens: contextTokens
        )
    }

    @available(macOS 15.4, iOS 26.0, *)
    private static func request(
        envelope: String,
        messages: [(role: String, content: String)],
        replayedToolPairs: [ReplayedToolPair] = [],
        toolResults: [(callID: String, output: String)] = [],
        pendingToolCalls: [ToolCall] = []
    ) -> ProviderStreamRequest {
        ProviderStreamRequest(
            provider: LocalProviderAdapter.providerProfile,
            model: ModelProfile(
                providerID: LocalProviderAdapter.providerProfile.id,
                remoteModelID: "qwen3.8-4b-heretic-mlx4",
                displayName: "Synthetic local",
                limits: .init(contextTokens: 8_192, maxOutputTokens: 1_024),
                capabilities: [.text, .tools]
            ),
            messages: [(role: "system", content: envelope)] + messages,
            toolResults: toolResults,
            pendingToolCalls: pendingToolCalls,
            replayedToolPairs: replayedToolPairs,
            toolSchemas: [
                ToolSchemaDescriptor(
                    name: "workspace.readFile",
                    description: "Read a workspace file",
                    parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}}}"#
                )
            ],
            allToolNames: ["workspace.readFile"]
        ).refreshingRuntimeClock()
    }

    @Test("A 12-character first greeting stays far below the Build229 prompt size")
    @available(macOS 15.4, iOS 26.0, *)
    func firstShortChatFitsBudget() throws {
        let greeting = "你好呀，今天过得怎么样？"
        #expect(greeting.count == 12)
        let build = LocalProviderAdapter.buildPrompt(for: Self.request(
            envelope: Self.boundedEnvelope(),
            messages: [(role: "user", content: greeting)]
        ))
        // Build229 at the same 8K window: estimatedPromptTokens 6,196,
        // systemCharacters 15,276, real prepared tokens 5,314 → crash inside
        // the prefill. The bounded envelope must be a fraction of that.
        #expect(build.systemInstructions.count < 7_000)
        #expect(build.estimatedPromptTokens < 3_400)
        #expect(build.estimatedPromptTokens < build.windowPromptTokenBudget)
        #expect(!build.exceedsContextWindow)
        // The current request is preserved exactly; the transcript carries
        // only the flattened user line.
        #expect(build.text == "USER: \(greeting)")
        // The stable base file-tool set is still offered (Build229 parity).
        #expect(build.selectedTools.contains { $0.name == "workspace.readFile" })
        #expect(build.systemInstructions.contains("OFFERED TOOLS"))
        #expect(build.systemInstructions.contains("workspace.readFile"))
        // The envelope kept its essential identity and marked its clipping.
        #expect(build.systemInstructions.contains("# Floe local runtime contract"))
        #expect(build.systemInstructions.contains("# Project instructions (FLOE.md/AGENTS.md)"))
        #expect(build.systemInstructions.contains("IOS AI AGENT"))
        print("FIRST-CHAT systemCharacters=\(build.systemInstructions.count) estimatedPromptTokens=\(build.estimatedPromptTokens) window=\(build.windowPromptTokenBudget)")
    }

    @Test("The same greeting against an unbounded envelope reproduces the Build229 scale")
    @available(macOS 15.4, iOS 26.0, *)
    func unboundedEnvelopeReproducesBuild229Scale() throws {
        let greeting = "你好呀，今天过得怎么样？"
        let unbounded = ConversationRunService.buildContextMessage(
            Self.deviceScaleContext(), mode: .chat, toolsAvailable: true, compactForLocal: true
        )
        let build = LocalProviderAdapter.buildPrompt(for: Self.request(
            envelope: unbounded,
            messages: [(role: "user", content: greeting)]
        ))
        // The synthetic workspace reproduces the device scale
        // (systemCharacters 15,276 / estimated 6,196), proving the budget
        // test above exercises the real failure mode and the bounded path
        // removes it.
        print("UNBOUNDED-FIRST-CHAT systemCharacters=\(build.systemInstructions.count) estimatedPromptTokens=\(build.estimatedPromptTokens)")
        #expect(build.systemInstructions.count > 12_000)
        #expect(build.estimatedPromptTokens > 4_400)
    }

    @Test("Two distinct tool turns keep both receipts and the offered schema under budget")
    @available(macOS 15.4, iOS 26.0, *)
    func twoToolTurnsKeepReceipts() throws {
        let envelope = Self.boundedEnvelope()
        let call1 = try ToolCall(
            id: "call-turn-1",
            toolName: "workspace.readFile",
            argumentsJSON: Data(#"{"path":"a.md"}"#.utf8),
            scope: .local
        )
        let receipt1 = "a.md 内容：第一轮工具回执必须保留。"
        let call2 = try ToolCall(
            id: "call-turn-2",
            toolName: "workspace.readFile",
            argumentsJSON: Data(#"{"path":"b.md"}"#.utf8),
            scope: .local
        )
        let receipt2 = "b.md 内容：第二轮工具回执也必须保留。"

        // Turn 1: the model issues the first call.
        let turn1 = LocalProviderAdapter.buildPrompt(for: Self.request(
            envelope: envelope,
            messages: [
                (role: "user", content: "读取 a.md 和 b.md 的内容"),
                (role: "assistant", content: "我先读取 a.md。")
            ],
            pendingToolCalls: [call1]
        ))
        #expect(turn1.text.contains("ASSISTANT TOOL REQUEST \(call1.id): workspace.readFile"))

        // Turn 2: the first receipt is pending evidence; the model issues the
        // second call in the same run.
        let turn2 = LocalProviderAdapter.buildPrompt(for: Self.request(
            envelope: envelope,
            messages: [
                (role: "user", content: "读取 a.md 和 b.md 的内容"),
                (role: "assistant", content: "我先读取 a.md。")
            ],
            toolResults: [(callID: call1.id, output: receipt1)],
            pendingToolCalls: [call2]
        ))
        #expect(turn2.text.contains("TOOL RESULT \(call1.id)"))
        #expect(turn2.text.contains(receipt1))
        #expect(turn2.text.contains("ASSISTANT TOOL REQUEST \(call2.id): workspace.readFile"))

        // Turn 3: both pairs settled; the newest receipt survives as pending
        // evidence and the first pair replays as earlier completed work.
        let turn3 = LocalProviderAdapter.buildPrompt(for: Self.request(
            envelope: envelope,
            messages: [
                (role: "user", content: "读取 a.md 和 b.md 的内容"),
                (role: "assistant", content: "两个文件都读完了。"),
                (role: "user", content: "把两份内容合并成一句话")
            ],
            replayedToolPairs: [ReplayedToolPair(call: call1, result: ToolResult(
                callID: call1.id,
                status: .ok,
                outputSummary: receipt1,
                outputDigest: "digest-1"
            ))],
            toolResults: [(callID: call2.id, output: receipt2)]
        ))
        #expect(turn3.text.contains("EARLIER TOOL CALL workspace.readFile id=\(call1.id)"))
        #expect(turn3.text.contains("EARLIER TOOL RESULT id=\(call1.id) status=ok"))
        #expect(turn3.text.contains("TOOL RESULT \(call2.id)"))
        #expect(turn3.text.contains(receipt2))
        #expect(turn3.text.contains("把两份内容合并成一句话"))
        // The offered schema never disappears; both turns stay inside budget.
        for build in [turn1, turn2, turn3] {
            #expect(build.selectedTools.contains { $0.name == "workspace.readFile" })
            #expect(build.estimatedPromptTokens < build.windowPromptTokenBudget)
            #expect(!build.exceedsContextWindow)
        }
        print("TWO-TURN turn3 estimatedPromptTokens=\(turn3.estimatedPromptTokens) transcriptCharacters=\(turn3.text.count)")
    }
}
