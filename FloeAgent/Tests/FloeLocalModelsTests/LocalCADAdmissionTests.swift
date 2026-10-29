import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
@testable import FloeLocalModels

@Suite("Local CAD tool admission")
struct LocalCADAdmissionTests {
    @Test("CAD annotation compaction preserves validation and named properties")
    @available(macOS 15.4, *)
    func constraintsArePreserved() throws {
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["action"],
            "description": String(repeating: "Authoring explanation. ", count: 700),
            "properties": [
                "action": ["type": "string", "enum": ["read", "query", "parameters", "material"]],
                "path": ["type": "string", "maxLength": 1024, "description": "Workspace-owned CAD document"],
                // A field named description is data, not a schema annotation.
                "description": ["type": "string", "maxLength": 120],
                "payload": ["type": "string"],
                "literal": ["const": ["description": "literal user data"]]
            ]
        ]
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: schema), as: UTF8.self)
        let original = ToolSchemaDescriptor(name: "cad.document", description: "CAD", parametersJSON: raw)
        let compact = LocalProviderAdapter.compactCADDescriptor(original)
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(compact.parametersJSON.utf8)) as? [String: Any])
        #expect(parsed["description"] == nil)
        #expect(parsed["required"] as? [String] == ["action"])
        #expect(parsed["additionalProperties"] as? Bool == false)
        let properties = try #require(parsed["properties"] as? [String: [String: Any]])
        #expect(properties["description"]?["maxLength"] as? Int == 120)
        #expect(properties["path"]?["maxLength"] as? Int == 1024)
        #expect(properties["action"]?["enum"] as? [String] == ["read", "query", "parameters", "material"])
        #expect((properties["literal"]?["const"] as? [String: String])?["description"] == "literal user data")
        #expect(compact.parametersJSON.count < 1_000)
        #expect(original.parametersJSON == raw)
        #expect(LocalProviderAdapter.compactCADDescriptor(.init(name: "web.search", description: "Search", parametersJSON: raw)).parametersJSON == raw)
    }

    @Test("CAD requests admit the actual registered tool into a bounded local prompt")
    @available(macOS 15.4, *)
    func localCADPrompt() throws {
        let provider = LocalProviderAdapter.providerProfile
        let model = ModelProfile(providerID: provider.id, remoteModelID: "qwen3.8-4b-heretic-mlx4",
            displayName: "Synthetic local", limits: .init(contextTokens: 4_096, maxOutputTokens: 512), capabilities: [.text, .tools])
        let schema: [String: Any] = ["type": "object", "required": ["action"], "additionalProperties": false,
            "description": String(repeating: "Detailed authoring example. ", count: 700),
            "properties": ["action": ["type": "string", "enum": ["capabilities", "query", "parameters"]],
                           "path": ["type": "string"], "kind": ["type": "string"], "payload": ["type": "string"]]]
        let cad = ToolSchemaDescriptor(name: "cad.document", description: "Inspect and edit CAD", parametersJSON: String(decoding: try JSONSerialization.data(withJSONObject: schema), as: UTF8.self))
        let tools = [cad, .init(name: "workspace.readFile", description: "Read files"),
                     .init(name: "web.search", description: "Search online"),
                     .init(name: "ssh.execute", description: "Remote execution")]
        let build = LocalProviderAdapter.buildPrompt(for: .init(provider: provider, model: model,
            messages: [("user", "把支架的孔径改为 8 毫米，增加圆角并改为磨砂金属材质")], toolSchemas: tools))
        #expect(build.selectedTools.contains { $0.name == "cad.document" })
        #expect(build.fallbackTools.contains { $0.name == "cad.document" })
        #expect(build.primaryRepairTool?.name == "cad.document")
        #expect(build.systemInstructions.contains("CAD TOOL ARGUMENTS (cad.document)"))
        #expect(build.systemInstructions.contains("Text-only models use geometry queries"))
        #expect(!build.fallbackTools.contains { $0.name == "ssh.execute" })
        #expect(!build.exceedsContextWindow)
        // An absent capability cannot be invented by the intent classifier.
        #expect(LocalProviderAdapter.admissibleToolNames(from: ["workspace.readFile"], modelRemoteID: model.remoteModelID) == ["workspace.readFile"])
        #expect(LocalProviderAdapter.admissibleToolNames(from: ["cad.document", "apple.location.current"], modelRemoteID: AppleFoundationModelIdentity.remoteModelID) == ["apple.location.current"])
    }
}
