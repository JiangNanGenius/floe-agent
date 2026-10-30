import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
@testable import FloeLocalModels

@Suite("Local CAD tool admission")
struct LocalCADAdmissionTests {
    private static let payloadVocabulary = """
    material list|read|create|update|apply|applyFaces|reassignFaces; parameters list|update|updateSketchEntity|setSketchDimension|feature.suppress|feature.delete|feature.move; animation list|query|evaluate|createClip|updateClip|deleteClip|addTrack|setKeyframe|setCameraKeyframe|setPartKeyframe|capture|export
    """

    private static func completeSchema(detail: String = String(repeating: "CAD authoring example. ", count: 40)) throws -> (raw: String, description: String) {
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
                "path": [
                    "type": "string",
                    "maxLength": 1024,
                    "description": "Workspace-owned CAD document"
                ],
                "payload": [
                    "type": "string",
                    "description": Self.payloadVocabulary + " " + detail
                ],
                "zz_last_field": [
                    "type": "string",
                    "description": "SENTINEL_LAST_FIELD"
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: schema)
        return (String(decoding: data, as: UTF8.self),
                "Inspect and edit native CAD documents with material, parameter and animation payloads.")
    }

    @Test("Complete CAD definition survives byte-for-byte when the actual window fits")
    @available(macOS 15.4, *)
    func completeCADDefinitionSurvivesLargeWindow() throws {
        let fixture = try Self.completeSchema()
        let cad = ToolSchemaDescriptor(
            name: "cad.document",
            description: fixture.description,
            parametersJSON: fixture.raw
        )
        let read = ToolSchemaDescriptor(name: "workspace.readFile", description: "Read files")
        let search = ToolSchemaDescriptor(name: "web.search", description: "Search online")
        let ssh = ToolSchemaDescriptor(name: "ssh.execute", description: "Remote execution")
        let provider = LocalProviderAdapter.providerProfile

        // Qwen-family JSON-envelope path: the chat template receives no native
        // schemas, so the complete definition must be in the envelope itself.
        let qwen = ModelProfile(
            providerID: provider.id,
            remoteModelID: "qwen3.8-4b-heretic-mlx4",
            displayName: "Synthetic local",
            limits: .init(contextTokens: 32_768, maxOutputTokens: 1_024),
            capabilities: [.text, .tools]
        )
        let qwenBuild = LocalProviderAdapter.buildPrompt(for: .init(
            provider: provider,
            model: qwen,
            messages: [("user", "把支架的孔径改为 8 毫米，增加圆角并改为磨砂金属材质")],
            toolSchemas: [cad, read, search, ssh]
        ))
        let qwenCAD = try #require(qwenBuild.selectedTools.first { $0.name == "cad.document" })
        #expect(qwenCAD.parametersJSON == fixture.raw)
        #expect(qwenCAD.description == fixture.description)
        #expect(qwenBuild.nativeToolSchemas.isEmpty)
        #expect(qwenBuild.systemInstructions.contains(fixture.raw))
        #expect(qwenBuild.systemInstructions.contains("material list|read|create|update|apply"))
        #expect(qwenBuild.systemInstructions.contains("setCameraKeyframe|setPartKeyframe"))
        #expect(qwenBuild.systemInstructions.contains("SENTINEL_LAST_FIELD"))
        #expect(qwenBuild.systemInstructions.contains("CAD TOOL ARGUMENTS (cad.document)"))
        #expect(qwenBuild.systemInstructions.contains("Text-only models use geometry queries"))
        #expect(qwenBuild.systemInstructions.contains(
            "the chat template receives no native tool schemas"
        ))
        #expect(!qwenBuild.exceedsContextWindow)
        #expect(qwenBuild.estimatedPromptTokens <= qwenBuild.windowPromptTokenBudget)
        #expect(qwenBuild.primaryRepairTool?.name == "cad.document")
        #expect(qwenBuild.fallbackTools.contains { $0.name == "ssh.execute" })
        #expect(qwenBuild.systemInstructions.contains("AVAILABLE TOOL NAMES"))
        #expect(!qwenBuild.systemInstructions.contains("SCHEMA BUDGET"))

        // Native-schema path: the exact definition is handed to the chat
        // template, without the old annotation stripper or description swap.
        let gemma = ModelProfile(
            providerID: provider.id,
            remoteModelID: "gemma4-e4b-mlx4",
            displayName: "Synthetic local",
            limits: .init(contextTokens: 32_768, maxOutputTokens: 1_024),
            capabilities: [.text, .tools]
        )
        let nativeBuild = LocalProviderAdapter.buildPrompt(for: .init(
            provider: provider,
            model: gemma,
            messages: [("user", "把支架的孔径改为 8 毫米，增加圆角并改为磨砂金属材质")],
            toolSchemas: [cad, read, search, ssh]
        ))
        let nativeCAD = try #require(nativeBuild.nativeToolSchemas.first { $0.name == "cad.document" })
        #expect(nativeCAD.parametersJSON == fixture.raw)
        #expect(nativeCAD.description == fixture.description)
        #expect(nativeBuild.selectedTools.first { $0.name == "cad.document" }?.parametersJSON == fixture.raw)
        #expect(!nativeBuild.systemInstructions.contains("SENTINEL_LAST_FIELD"))
        #expect(!nativeBuild.exceedsContextWindow)
        #expect(nativeBuild.estimatedPromptTokens <= nativeBuild.windowPromptTokenBudget)

        // An absent capability cannot be invented by the intent classifier.
        #expect(LocalProviderAdapter.admissibleToolNames(
            from: ["workspace.readFile"], modelRemoteID: qwen.remoteModelID
        ) == ["workspace.readFile"])
        #expect(LocalProviderAdapter.admissibleToolNames(
            from: ["cad.document", "apple.location.current"],
            modelRemoteID: AppleFoundationModelIdentity.remoteModelID
        ) == ["apple.location.current"])
    }

    @Test("A definition larger than the realistic window is deferred whole, never sliced")
    @available(macOS 15.4, *)
    func oversizedCADDefinitionIsDeferredWhole() throws {
        let fixture = try Self.completeSchema(
            detail: String(repeating: "X", count: 20_000)
        )
        let cad = ToolSchemaDescriptor(
            name: "cad.document",
            description: fixture.description,
            parametersJSON: fixture.raw
        )
        let read = ToolSchemaDescriptor(name: "workspace.readFile", description: "Read files")
        let toolSearch = ToolSchemaDescriptor(
            name: "tools.search",
            description: "Load one exact tool definition",
            parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}}}"#
        )
        let provider = LocalProviderAdapter.providerProfile
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "qwen3.8-4b-heretic-mlx4",
            displayName: "Synthetic local",
            limits: .init(contextTokens: 4_096, maxOutputTokens: 512),
            capabilities: [.text, .tools]
        )
        let build = LocalProviderAdapter.buildPrompt(for: .init(
            provider: provider,
            model: model,
            // An explicit edit request that pins CAD first.
            messages: [("user", "修改支架的孔径为 8 毫米，增加圆角")],
            toolSchemas: [toolSearch, cad, read]
        ))
        #expect(!build.selectedTools.contains { $0.name == "cad.document" })
        #expect(build.fallbackTools.contains { $0.name == "cad.document" })
        #expect(build.fallbackTools.contains { $0.name == "workspace.readFile" })
        #expect(build.systemInstructions.contains("SCHEMA BUDGET"))
        #expect(build.systemInstructions.contains("deferred rather than sliced"))
        #expect(build.systemInstructions.contains("Load one exact name with tools.search"))
        #expect(build.systemInstructions.contains("did not fit this model window"))
        // The giant annotation must not appear as a sliced prefix anywhere.
        #expect(!build.systemInstructions.contains("SENTINEL_LAST_FIELD"))
        #expect(!build.systemInstructions.contains(String(repeating: "X", count: 200)))
        #expect(!build.selectedTools.contains { $0.parametersJSON.contains("XXXXX") })
        // No unrelated substitute is forced when the intended definition did
        // not fit; the model gets an explicit discovery path instead.
        #expect(!build.requiresToolCall)
        #expect(!build.exceedsContextWindow)
        #expect(build.estimatedPromptTokens <= build.windowPromptTokenBudget)
        #expect(build.selectedTools.contains { $0.name == "tools.search" })
    }
}
