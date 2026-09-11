import Foundation
import Testing
@testable import FloeCore

struct ProviderTraitsTests {
    private func provider(
        kind: ProviderKind = .custom,
        url: String,
        displayName: String? = nil,
        compatibility: Bool = false
    ) throws -> ProviderProfile {
        ProviderProfile(
            id: UUID(),
            kind: kind,
            wireProtocol: .openAIChatCompletions,
            baseURL: try #require(URL(string: url)),
            displayName: displayName,
            toolNameCompatibility: compatibility
        )
    }

    private func model(_ provider: ProviderProfile, id: String) -> ModelProfile {
        ModelProfile(
            providerID: provider.id,
            remoteModelID: id,
            displayName: id,
            limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 8_192)
        )
    }

    @Test("DeepSeek detection agrees across host, display name and model id")
    func deepSeekDetection() throws {
        let host = try provider(url: "https://api.deepseek.com")
        let renamed = try provider(url: "https://gateway.example.com", displayName: "DeepSeek Relay")
        let byModel = try provider(url: "https://gateway.example.com")
        let plain = try provider(url: "https://api.example.com")

        #expect(host.traits().isDeepSeek)
        #expect(renamed.traits().isDeepSeek)
        #expect(byModel.traits(model: model(byModel, id: "deepseek-flash")).isDeepSeek)
        #expect(!plain.traits().isDeepSeek)
    }

    @Test("Wire-safe tool names and reasoning replay share one decision")
    func traitsAgree() throws {
        let byModel = try provider(url: "https://gateway.example.com")
        let traits = byModel.traits(model: model(byModel, id: "deepseek-v4-pro"))
        #expect(traits.usesWireSafeToolNames)
        #expect(traits.requiresReasoningReplay)

        let toggled = try provider(url: "https://api.example.com", compatibility: true)
        #expect(toggled.traits().usesWireSafeToolNames)
        #expect(!toggled.traits().requiresReasoningReplay)
    }

    @Test("ToolNameSpelling resolves wire and case drift, rejects ambiguity")
    func spelling() {
        let universe = ["workspace.readFile", "document.pdf.render", "tools.list"]
        #expect(ToolNameSpelling.wire("workspace.readFile", safe: true) == "workspace_readFile")
        #expect(ToolNameSpelling.wire("workspace.readFile", safe: false) == "workspace.readFile")
        #expect(ToolNameSpelling.canonical("workspace_readFile", among: universe) == "workspace.readFile")
        #expect(ToolNameSpelling.canonical("workspace_readfile", among: universe) == "workspace.readFile")
        #expect(ToolNameSpelling.canonical("tools_list", among: universe) == "tools.list")
        #expect(ToolNameSpelling.canonical("Workspace.ReadFile", among: universe) == "workspace.readFile")
        #expect(ToolNameSpelling.canonical("unknown_tool", among: universe) == nil)
        #expect(ToolNameSpelling.canonical("a_b_c", among: ["a.b_c", "a_b.c"]) == nil)
    }
}
