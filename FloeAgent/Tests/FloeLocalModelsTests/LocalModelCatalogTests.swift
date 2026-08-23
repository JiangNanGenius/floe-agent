import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
@testable import FloeLocalModelCatalog
@testable import FloeLocalModels

@Suite("Local model catalog")
struct LocalModelCatalogTests {
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

    @Test("Curated entries are downloadable Apache models")
    func curatedEntries() {
        #expect(CuratedLocalModelCatalog.entries.count == 2)
        #expect(!CuratedLocalModelCatalog.entries.contains { $0.id == "qwen3.5-9b-q4km" })
        #expect(CuratedLocalModelCatalog.retiredEntries.contains { $0.id == "qwen3.5-9b-q4km" })
        for entry in CuratedLocalModelCatalog.entries {
            #expect(entry.modelURL.scheme == "https")
            #expect(entry.license == "Apache-2.0")
            #expect(entry.supportsToolCalling)
            #expect(entry.approximateDownloadBytes > 1_000_000_000)
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
            mappedBytes: 6 * gib,
            physicalMemoryBytes: 8 * gib
        ))

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
            remoteModelID: "qwen3.5-4b-q4km",
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
        #expect(build.text.contains("unrelated.tool0"))
        #expect(build.text.contains("AVAILABLE TOOL NAMES"))
        #expect(build.text.contains("/no_think"))
        #expect(!build.text.contains("SYSTEM:"))
        #expect(!build.text.contains(String(repeating: "large cloud harness ", count: 20)))
    }

    @Test("Local prompt offers only intent-relevant tools")
    @available(macOS 15.4, *)
    func localPromptSelectsRelevantTools() {
        let provider = LocalProviderAdapter.providerProfile
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "qwen3.5-4b-q4km",
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

        #expect(build.selectedToolCount == 3)
        #expect(build.text.contains("workspace.readFile"))
        #expect(build.text.contains("pdf.read"))
        #expect(build.text.contains("presentation.create"))
        #expect(!build.text.contains("- ssh.execute:"))
        #expect(build.text.count < 5_000)
    }

    @Test("Local capability questions can see the authoritative tool directory")
    @available(macOS 15.4, *)
    func localPromptExposesToolDirectory() {
        let provider = LocalProviderAdapter.providerProfile
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "qwen3.5-4b-q4km",
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

        #expect(build.selectedToolCount == tools.count)
        for tool in tools {
            #expect(build.text.contains(tool.name))
        }
        #expect(build.text.contains("AVAILABLE TOOL NAMES"))
        #expect(build.text.count < 5_000)
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
}
