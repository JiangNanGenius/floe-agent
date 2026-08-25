import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
@testable import FloeLocalModelCatalog
@testable import FloeLocalModels

@Suite("Local model catalog")
struct LocalModelCatalogTests {
    @Test("Release toolchain compiles the real Foundation Models integration")
    func foundationModelsSDKIsCompiled() {
        #expect(AppleFoundationModelRuntime.sdkIntegrationCompiled)
    }

    @Test("Local task residency unloads only after the last task finishes")
    func localTaskResidencyLedger() {
        let first = UUID()
        let second = UUID()
        var ledger = LocalModelTaskResidencyLedger()

        ledger.retain(taskID: first, modelID: "local-a")
        ledger.retain(taskID: second, modelID: "local-a")
        #expect(ledger.activeTaskCount == 2)
        let firstWasLast = ledger.release(taskID: first)
        #expect(!firstWasLast)
        #expect(ledger.activeTaskCount == 1)
        let secondWasLast = ledger.release(taskID: second)
        #expect(secondWasLast)
        #expect(ledger.activeTaskCount == 0)
        let duplicateWasLast = ledger.release(taskID: second)
        #expect(!duplicateWasLast)
    }

    @Test("Recovered local task retention is idempotent")
    func localTaskResidencyRecoveryIsIdempotent() {
        let runID = UUID()
        var ledger = LocalModelTaskResidencyLedger()

        ledger.retain(taskID: runID, modelID: "local-a")
        ledger.retain(taskID: runID, modelID: "local-a")
        #expect(ledger.activeTaskCount == 1)
        let wasLast = ledger.release(taskID: runID)
        #expect(wasLast)
    }

    @Test("Local residency switches silently only before the first load")
    func residencySelectionPolicy() {
        #expect(LocalModelResidencyPolicy.decision(
            residentModelID: nil,
            targetModelID: "local-a"
        ) == .preloadSilently)
        #expect(LocalModelResidencyPolicy.decision(
            residentModelID: "local-a",
            targetModelID: "local-a"
        ) == .useResident)
        #expect(LocalModelResidencyPolicy.decision(
            residentModelID: "local-a",
            targetModelID: "local-b"
        ) == .confirmReplacement(currentModelID: "local-a"))
    }

    @Test("Public catalog contains only immutable curated MLX snapshots")
    func curatedEntries() {
        #expect(CuratedLocalModelCatalog.entries.count == 3)
        #expect(!CuratedLocalModelCatalog.entries.contains { $0.id == "qwen3.5-9b-q4km" })
        #expect(!CuratedLocalModelCatalog.entries.contains { $0.id == "ministral3-3b-q4km" })
        #expect(CuratedLocalModelCatalog.retiredEntries.contains { $0.id == "qwen3.5-9b-q4km" })
        #expect(CuratedLocalModelCatalog.retiredEntries.contains { $0.id == "ministral3-3b-q4km" })
        let publicProfileIDs = CuratedLocalModelCatalog.entries.map(\.profileID)
        #expect(Set(publicProfileIDs).count == publicProfileIDs.count)
        #expect(publicProfileIDs.allSatisfy(ProviderProfile.onDeviceModelIDs.contains))
        #expect(!publicProfileIDs.contains(AppleFoundationModelIdentity.profileID))
        for entry in CuratedLocalModelCatalog.entries {
            #expect(entry.runtimeFormat == .mlx)
            #expect(entry.revision.count == 40)
            #expect(!entry.artifacts.isEmpty)
            #expect(entry.artifacts.allSatisfy { entry.artifactURL($0).scheme == "https" })
            #expect(entry.artifacts.allSatisfy { entry.artifactURL($0).path.contains(entry.revision) })
            #expect(entry.supportsToolCalling)
            #expect(entry.approximateDownloadBytes > 1_000_000_000)
        }

        let qwen38 = CuratedLocalModelCatalog.entries.first {
            $0.id == "qwen3.8-4b-heretic-mlx4"
        }
        #expect(qwen38?.repository == "yachen4ever/Qwen3.8-4B-Distill-Heretic-Abliterated-MLX-4bit")
        #expect(qwen38?.artifacts.contains { $0.path == "model.safetensors" } == true)
        #expect(qwen38?.license == "Apache-2.0")
        #expect(qwen38?.parameterBillions == 4)
        #expect(qwen38?.supportsVision == true)
        #expect(qwen38?.supportsReasoning == true)

        let gemma4 = CuratedLocalModelCatalog.entries.first {
            $0.id == "gemma4-e4b-mlx4"
        }
        #expect(gemma4?.repository == "mlx-community/gemma-4-e4b-it-4bit")
        #expect(gemma4?.license == "Gemma")
        #expect(gemma4?.parameterBillions == 4.5)
        #expect(gemma4?.approximateDownloadBytes == 5_179_239_349)
        #expect(gemma4?.supportsVision == true)
        #expect(gemma4?.supportsReasoning == true)
    }

    @Test("Safetensors validation checks its bounded JSON header")
    func safetensorsSignature() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let valid = directory.appendingPathComponent("model.safetensors")
        let header = Data(#"{"weight":{"dtype":"F16","shape":[1],"data_offsets":[0,2]}}"#.utf8)
        var length = UInt64(header.count).littleEndian
        var bytes = withUnsafeBytes(of: &length) { Data($0) }
        bytes.append(header)
        bytes.append(contentsOf: [0, 0])
        try bytes.write(to: valid)
        try LocalModelStore.validateSafetensors(valid)

        let invalid = directory.appendingPathComponent("invalid.safetensors")
        try Data([0, 1, 2, 3]).write(to: invalid)
        #expect(throws: LocalModelStore.StoreError.self) {
            try LocalModelStore.validateSafetensors(invalid)
        }
    }

    @Test("GGUF validation uses file signature")
    func ggufSignature() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let valid = directory.appendingPathComponent("model.gguf")
        try Data([0x47, 0x47, 0x55, 0x46, 0, 0, 0, 0]).write(to: valid)
        try LocalModelStore.validateGGUF(valid)

        let invalid = directory.appendingPathComponent("model.bin")
        try Data("not a model".utf8).write(to: invalid)
        #expect(throws: LocalModelStore.StoreError.self) {
            try LocalModelStore.validateGGUF(invalid)
        }
    }

    @Test("Resume records are discovered without treating unknown directories as models")
    func discoversResumeRecords() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let knownID = try #require(CuratedLocalModelCatalog.entries.first?.id)
        let known = root.appendingPathComponent(".downloads/\(knownID)", isDirectory: true)
        let unknown = root.appendingPathComponent(".downloads/not-in-catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: known, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: known.appendingPathComponent("weights.resume"))
        try Data([1, 2, 3]).write(to: unknown.appendingPathComponent("weights.resume"))

        let resumable = await LocalModelStore(root: root).resumableModelIDs()
        #expect(resumable == Set([knownID]))
    }

    @Test("Inference resource policy preserves headroom and adapts offload")
    func inferenceResourcePolicy() {
        let gib: UInt64 = 1_073_741_824
        #expect(LocalInferenceResourcePolicy.canLoad(
            mappedBytes: 4 * gib,
            physicalMemoryBytes: 8 * gib
        ))
        #expect(LocalInferenceResourcePolicy.canLoad(
            mappedBytes: 3 * gib,
            physicalMemoryBytes: 8 * gib
        ))
        #expect(!LocalInferenceResourcePolicy.canLoad(
            mappedBytes: 9 * gib,
            physicalMemoryBytes: 8 * gib
        ))
        // Gemma 4's mapped snapshot may be slightly larger than the current
        // 4.7-4.9 GiB process allowance on an M4 iPad. MLX maps weights lazily,
        // so this is allowed while a clearly larger snapshot is still denied.
        #expect(LocalInferenceResourcePolicy.canLoad(
            mappedBytes: 5_146_800_534,
            physicalMemoryBytes: 4_900_000_000
        ))
        #expect(!LocalInferenceResourcePolicy.canLoad(
            mappedBytes: 6_000_000_000,
            physicalMemoryBytes: 4_900_000_000
        ))

        let minimumScratch = LocalInferenceResourcePolicy.profile(
            mappedBytes: 5_146_800_534,
            physicalMemoryBytes: 5_264_538_280
        )
        #expect(minimumScratch.tier == .constrained)
        #expect(minimumScratch.contextSize == 2_048)
        #expect(minimumScratch.batchSize == 32)
        #expect(minimumScratch.maximumOutputTokens == 256)

        let constrained = LocalInferenceResourcePolicy.profile(
            mappedBytes: 5 * gib,
            physicalMemoryBytes: 8 * gib
        )
        #expect(constrained.contextSize == 4_096)
        #expect(constrained.tier == .constrained)
        #expect(constrained.batchSize == 96)
        #expect(constrained.gpuLayers == 16)

        let roomy = LocalInferenceResourcePolicy.profile(
            mappedBytes: 3 * gib,
            physicalMemoryBytes: 16 * gib
        )
        #expect(roomy.contextSize == 16_384)
        #expect(roomy.tier == .roomy)
        #expect(roomy.gpuLayers == 99)
        #expect(roomy.maximumOutputTokens == 1_536)

        let balanced = LocalInferenceResourcePolicy.profile(
            mappedBytes: 3 * gib,
            physicalMemoryBytes: 8 * gib
        )
        #expect(balanced.contextSize == 8_192)
        #expect(balanced.tier == .balanced)
        #expect(balanced.maximumOutputTokens == 1_024)
    }

    @Test("Local prompt drops the cloud harness and stays within the device context")
    @available(macOS 15.4, *)
    func localPromptIsBounded() {
        let provider = LocalProviderAdapter.providerProfile
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "qwen3.5-4b-mlx4",
            displayName: "Qwen local",
            limits: .init(contextTokens: 4_096, maxOutputTokens: 1_024),
            capabilities: [.text, .tools]
        )
        let tools = (0..<68).map { index in
            ToolSchemaDescriptor(
                name: "unrelated.tool\(index)",
                description: String(repeating: "description", count: 20),
                parametersJSON: #"{"type":"object","properties":{"value":{"type":"string"}}}"#
            )
        }
        let request = ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: [
                ("system", String(repeating: "large cloud harness ", count: 2_500)),
                ("user", "你好")
            ],
            toolSchemas: tools
        )

        let build = LocalProviderAdapter.buildPrompt(for: request)

        #expect(build.sourceCharacters > 40_000)
        #expect(build.text.count < 5_000)
        #expect(build.selectedToolCount == 0)
        #expect(build.text.contains("你好"))
        #expect(!build.text.contains("unrelated.tool0"))
        #expect(!build.text.contains("AVAILABLE TOOL NAMES"))
        #expect(build.systemInstructions.contains("Think silently"))
        #expect(build.systemInstructions.contains("Reply directly in natural language"))
        #expect(build.systemInstructions.contains("never demand a more explicit task"))
        #expect(!build.systemInstructions.contains("emit the documented single JSON tool_call"))
        #expect(!build.text.contains("<|im_start|>"))
        #expect(!build.text.contains("SYSTEM:"))
        #expect(!build.text.contains(String(repeating: "large cloud harness ", count: 20)))
    }

    @Test("Apple Foundation Model treats casual chat as a complete request")
    @available(macOS 15.4, *)
    func appleCasualChatDoesNotDemandAnAction() {
        let provider = LocalProviderAdapter.providerProfile
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: AppleFoundationModelIdentity.remoteModelID,
            displayName: "Apple Foundation Model",
            limits: .init(contextTokens: 4_096, maxOutputTokens: 512),
            capabilities: [.text, .tools]
        )
        let build = LocalProviderAdapter.buildPrompt(for: ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: [("user", "你好，今天过得怎么样？")],
            toolSchemas: [ToolSchemaDescriptor(name: "apple.automation.list", description: "List shortcuts")]
        ))
        #expect(build.selectedTools.isEmpty)
        #expect(!build.text.contains("AVAILABLE TOOL NAMES"))
        #expect(build.systemInstructions.contains("ordinary conversation"))
        #expect(build.systemInstructions.contains("Respond normally and warmly"))
    }

    @Test("Apple native tools never receive or parse the MLX JSON fallback protocol")
    @available(macOS 15.4, *)
    func appleNativeToolsDoNotUseJSONFallback() throws {
        let provider = LocalProviderAdapter.providerProfile
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: AppleFoundationModelIdentity.remoteModelID,
            displayName: "Apple Foundation Model",
            limits: .init(contextTokens: 4_096, maxOutputTokens: 512),
            capabilities: [.text, .tools]
        )
        let tool = ToolSchemaDescriptor(
            name: "apple.automation.list",
            description: "List shortcuts"
        )
        let build = LocalProviderAdapter.buildPrompt(for: ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: [("user", "列出快捷指令")],
            toolSchemas: [tool]
        ))
        #expect(build.selectedTools.map(\.name) == [tool.name])
        #expect(!build.text.contains("{\"tool_call\""))
        #expect(!build.systemInstructions.contains("emit the documented single JSON"))

        let printedJSON = #"{"tool_call":{"name":"apple.automation.list","arguments":{}}}"#
        let parsed = try LocalProviderAdapter.fallbackToolCall(
            from: printedJSON,
            modelRemoteID: model.remoteModelID,
            selectedTools: [tool]
        )
        #expect(parsed == nil)
    }

    @Test("Constrained local context admits a small tool set")
    @available(macOS 15.4, *)
    func constrainedLocalPromptLimitsSchemas() {
        let provider = LocalProviderAdapter.providerProfile
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "gemma4-e4b-mlx4",
            displayName: "Gemma local",
            limits: .init(contextTokens: 2_048, maxOutputTokens: 256),
            capabilities: [.text, .tools]
        )
        let tools = (0..<20).map { index in
            ToolSchemaDescriptor(
                name: "workspace.tool\(index)",
                description: "Workspace operation \(index)",
                parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}}}"#
            )
        }
        let build = LocalProviderAdapter.buildPrompt(for: ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: [("user", "测试所有工作区工具")],
            toolSchemas: tools
        ))
        #expect(build.selectedToolCount <= 4)
        #expect(build.text.count < 3_000)
    }

    @Test("MLX prompt offers only simple intent-relevant tools")
    @available(macOS 15.4, *)
    func localPromptSelectsRelevantTools() {
        let provider = LocalProviderAdapter.providerProfile
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "qwen3.5-4b-mlx4",
            displayName: "Qwen local",
            limits: .init(contextTokens: 4_096, maxOutputTokens: 1_024),
            capabilities: [.text, .tools]
        )
        let tools = [
            ToolSchemaDescriptor(name: "workspace.readFile", description: "Read a file"),
            ToolSchemaDescriptor(name: "pdf.read", description: "Read a PDF"),
            ToolSchemaDescriptor(name: "presentation.create", description: "Create a chart"),
            ToolSchemaDescriptor(name: "browser.click", description: "Click browser"),
            ToolSchemaDescriptor(name: "ssh.execute", description: "Run SSH")
        ]
        let request = ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: [("user", "读取 PDF 并生成图表")],
            toolSchemas: tools
        )

        let build = LocalProviderAdapter.buildPrompt(for: request)

        #expect(build.selectedToolCount == 2)
        #expect(build.systemInstructions.contains("emit the documented single JSON tool_call"))
        #expect(build.selectedTools.map(\.name) == [
            "pdf.read", "workspace.readFile"
        ])
        #expect(build.text.contains("workspace.readFile"))
        #expect(build.text.contains("pdf.read"))
        #expect(!build.text.contains("presentation.create"))
        #expect(!build.text.contains("browser.click"))
        #expect(!build.text.contains("- ssh.execute:"))
        #expect(build.text.count < 5_000)
    }

    @Test("Apple tool follow-up uses structured history and requests a natural answer")
    @available(macOS 15.4, *)
    func appleToolFollowUpDisablesAnotherCall() throws {
        let provider = LocalProviderAdapter.providerProfile
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: AppleFoundationModelIdentity.remoteModelID,
            displayName: "Apple Foundation Model",
            limits: .init(contextTokens: 4_096, maxOutputTokens: 512),
            capabilities: [.text, .tools]
        )
        let call = try ToolCall(
            id: "apple-call",
            toolName: "apple.automation.list",
            argumentsJSON: Data(#"{}"#.utf8),
            scope: .local
        )
        let build = LocalProviderAdapter.buildPrompt(for: ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: [("user", "列出快捷指令")],
            toolResults: [(callID: call.id, output: "快捷指令 A")],
            pendingToolCalls: [call],
            toolSchemas: [ToolSchemaDescriptor(
                name: call.toolName,
                description: "List shortcuts"
            )]
        ))
        #expect(build.selectedTools.isEmpty)
        #expect(build.systemInstructions.contains("Reply directly in natural language"))
        #expect(!build.text.contains("PENDING_EXTERNAL_EXECUTION"))
        #expect(!build.text.contains("TOOL RESULT"))
    }

    @Test("Local capability questions can see the authoritative tool directory")
    @available(macOS 15.4, *)
    func localPromptExposesToolDirectory() {
        let provider = LocalProviderAdapter.providerProfile
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "qwen3.5-4b-mlx4",
            displayName: "Qwen local",
            limits: .init(contextTokens: 4_096, maxOutputTokens: 1_024),
            capabilities: [.text, .tools]
        )
        let tools = [
            ToolSchemaDescriptor(name: "workspace.readFile", description: "Read a file"),
            ToolSchemaDescriptor(name: "image.inspect", description: "Inspect an image"),
            ToolSchemaDescriptor(name: "ssh.execute", description: "Run SSH"),
            ToolSchemaDescriptor(name: "apple.calendar.list", description: "List calendar events")
        ]
        let request = ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: [("user", "你能看到哪些工具？")],
            toolSchemas: tools
        )

        let build = LocalProviderAdapter.buildPrompt(for: request)

        #expect(build.selectedTools.map(\.name) == ["image.inspect", "workspace.readFile"])
        #expect(!build.text.contains("ssh.execute"))
        #expect(!build.text.contains("apple.calendar.list"))
        #expect(build.text.contains("AVAILABLE TOOL NAMES"))
        #expect(build.text.count < 5_000)
    }

    @Test("MLX Git requests receive only read-only local Git tools")
    @available(macOS 15.4, *)
    func localPromptSelectsGitTools() {
        let provider = LocalProviderAdapter.providerProfile
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "qwen3.5-4b-mlx4",
            displayName: "Qwen local",
            limits: .init(contextTokens: 8_192, maxOutputTokens: 1_024),
            capabilities: [.text, .tools]
        )
        let tools = [
            ToolSchemaDescriptor(name: "workspace.readFile", description: "Read a file"),
            ToolSchemaDescriptor(name: "git.status", description: "Git status"),
            ToolSchemaDescriptor(name: "git.diff", description: "Git diff"),
            ToolSchemaDescriptor(name: "git.log", description: "Git log"),
            ToolSchemaDescriptor(name: "git.stage", description: "Stage changes"),
            ToolSchemaDescriptor(name: "git.commit", description: "Commit changes"),
            ToolSchemaDescriptor(name: "git.push", description: "Push changes"),
            ToolSchemaDescriptor(name: "github.repositories", description: "List repositories"),
            ToolSchemaDescriptor(name: "cloudWorkspace.gitStatus", description: "Cloud Git status"),
            ToolSchemaDescriptor(name: "cloudWorkspace.gitPush", description: "Cloud Git push"),
            ToolSchemaDescriptor(name: "ssh.execute", description: "Run SSH")
        ]

        let local = LocalProviderAdapter.buildPrompt(for: ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: [("user", "查看本地仓库状态，暂存并提交代码，然后推送 GitHub")],
            toolSchemas: tools
        ))
        #expect(local.selectedTools.contains { $0.name == "git.status" })
        #expect(local.selectedTools.contains { $0.name == "git.diff" })
        #expect(local.selectedTools.contains { $0.name == "git.log" })
        #expect(!local.selectedTools.contains { $0.name == "git.stage" })
        #expect(!local.selectedTools.contains { $0.name == "git.commit" })
        #expect(!local.selectedTools.contains { $0.name == "git.push" })
        #expect(!local.selectedTools.contains { $0.name == "github.repositories" })
        #expect(!local.selectedTools.contains { $0.name == "ssh.execute" })

        let cloud = LocalProviderAdapter.buildPrompt(for: ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: [("user", "检查云工作区 Git 状态并推送")],
            toolSchemas: tools
        ))
        #expect(cloud.selectedTools.contains { $0.name == "git.status" })
        #expect(cloud.selectedTools.contains { $0.name == "git.diff" })
        #expect(cloud.selectedTools.contains { $0.name == "git.log" })
        #expect(!cloud.selectedTools.contains { $0.name.hasPrefix("cloudWorkspace.") })
    }

    @Test("Local reasoning tags are separated from the visible answer")
    @available(macOS 15.4, *)
    func localReasoningTagsAreSeparated() {
        let channels = LocalProviderAdapter.splitReasoning(
            from: "<think>先检查约束，再回答。</think>\n这是最终回答。"
        )
        #expect(channels.reasoning == "先检查约束，再回答。")
        #expect(channels.answer == "这是最终回答。")
        #expect(!channels.answer.contains("<think>"))
    }

    @Test("Stray local reasoning tags never leak into titles")
    @available(macOS 15.4, *)
    func strayLocalReasoningTagsAreRemoved() {
        let channels = LocalProviderAdapter.splitReasoning(
            from: "<think></think></think>I'm ready to help."
        )
        #expect(channels.reasoning.isEmpty)
        #expect(channels.answer == "I'm ready to help.")
    }

    @Test("Untagged local planning is hidden and the final revision is retained")
    @available(macOS 15.4, *)
    func untaggedPlanningIsSeparated() {
        let channels = LocalProviderAdapter.splitReasoning(from: """
        Thinking Process:
        1. Analyze the request.
        Draft: 你好，我可以帮助你。
        Revised Draft: 你好，请告诉我具体需求。
        Even shorter: 你好！请告诉我具体需求。
        """)

        #expect(channels.reasoning.contains("Thinking Process"))
        #expect(channels.answer == "你好！请告诉我具体需求。")
    }

    @Test("Reasoning-only local output is not promoted to a visible answer")
    @available(macOS 15.4, *)
    func reasoningOnlyOutputIsEmpty() {
        let channels = LocalProviderAdapter.splitReasoning(
            from: "Thinking Process:\nI will inspect the request without answering."
        )
        #expect(!channels.reasoning.isEmpty)
        #expect(channels.answer.isEmpty)
    }

    @Test("Local tool calls tolerate prose, fences, and nested function envelopes")
    @available(macOS 15.4, *)
    func tolerantLocalToolCalls() throws {
        let offered: Set<String> = ["apple.automation.list", "workspace.readFile"]

        let prose = try LocalProviderAdapter.toolCall(
            from: "我来查看。\n<tool_call>{\"tool_call\":{\"name\":\"apple.automation.list\",\"arguments\":{}}}</tool_call>",
            offeredToolNames: offered
        )
        #expect(prose?.toolName == "apple.automation.list")

        let fenced = try LocalProviderAdapter.toolCall(
            from: """
            ```json
            {"tool_calls":[{"type":"function","function":{"name":"workspace.readFile","arguments":"{\\"path\\":\\"notes.md\\"}"}}]}
            ```
            """,
            offeredToolNames: offered
        )
        #expect(fenced?.toolName == "workspace.readFile")
        #expect(String(decoding: try #require(fenced?.argumentsJSON), as: UTF8.self).contains("notes.md"))

        let browserAlias = try LocalProviderAdapter.toolCall(
            from: #"{"name":"browser.get","arguments":{"url":"https://example.com"}}"#,
            offeredToolNames: ["web.fetch"]
        )
        #expect(browserAlias?.toolName == "web.fetch")
    }

    @Test("Apple weather questions select and require native web search")
    @available(macOS 15.4, *)
    func appleWeatherUsesNativeTool() {
        let provider = LocalProviderAdapter.providerProfile
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: AppleFoundationModelIdentity.remoteModelID,
            displayName: "Apple Foundation Model",
            limits: .init(contextTokens: 4_096, maxOutputTokens: 512),
            capabilities: [.text, .tools]
        )
        let build = LocalProviderAdapter.buildPrompt(for: ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: [("user", "你帮我查一下今天的天气")],
            toolSchemas: [
                ToolSchemaDescriptor(name: "web.search", description: "Search the web"),
                ToolSchemaDescriptor(name: "browser.navigate", description: "Open a browser")
            ]
        ))
        #expect(build.selectedTools.map(\.name).contains("web.search"))
        #expect(build.requiresToolCall)
        #expect(build.systemInstructions.contains("native Foundation Models tools"))
    }

    @Test("Local tool parser rejects tools not offered on the turn")
    @available(macOS 15.4, *)
    func localToolCallCapabilityBoundary() throws {
        let call = try LocalProviderAdapter.toolCall(
            from: #"{"tool_call":{"name":"ssh.execute","arguments":{}}}"#,
            offeredToolNames: ["workspace.readFile"]
        )
        #expect(call == nil)
    }

    @Test("Local JSON fallback preserves SSH host scope")
    @available(macOS 15.4, *)
    func localToolFallbackHostScope() throws {
        let hostID = UUID()
        let call = try #require(try LocalProviderAdapter.toolCall(
            from: """
            {"tool_call":{"name":"ssh.execute","arguments":{"hostID":"\(hostID.uuidString)","command":"uname -a"}}}
            """,
            offeredToolNames: ["ssh.execute"]
        ))
        #expect(call.scope == .host(hostID))
    }

    @Test("Legacy Apple tool-result envelope renders as natural language")
    @available(macOS 15.4, *)
    func legacyAppleResultEnvelopeIsUnwrapped() {
        #expect(LocalProviderAdapter.visibleAnswer(
            from: #"{"tool":"apple.automation.list","result":"你好"}"#
        ) == "你好")
        #expect(LocalProviderAdapter.visibleAnswer(
            from: #"{"tool_call":{"name":"apple.automation.list","arguments":{}}}"#
        ).contains("tool_call"))
    }
}
