import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
@testable import FloeLocalModelCatalog
@testable import FloeLocalModels

@Suite("Local model catalog")
struct LocalModelCatalogTests {
    @Test("Curated entries are downloadable Apache models")
    func curatedEntries() {
        #expect(CuratedLocalModelCatalog.entries.count >= 3)
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
            mappedBytes: 4 * gib,
            physicalMemoryBytes: 8 * gib
        )
        #expect(constrained.contextSize == 3_072)
        #expect(constrained.tier == .constrained)
        #expect(constrained.batchSize == 96)
        #expect(constrained.gpuLayers == 16)

        let roomy = LocalInferenceResourcePolicy.profile(
            mappedBytes: 3 * gib,
            physicalMemoryBytes: 16 * gib
        )
        #expect(roomy.contextSize == 8_192)
        #expect(roomy.tier == .roomy)
        #expect(roomy.gpuLayers == 99)
        #expect(roomy.maximumOutputTokens == 1_536)

        let balanced = LocalInferenceResourcePolicy.profile(
            mappedBytes: 3 * gib,
            physicalMemoryBytes: 8 * gib
        )
        #expect(balanced.contextSize == 4_096)
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
        #expect(!build.text.contains("ssh.execute"))
        #expect(build.text.count < 5_000)
    }
}
