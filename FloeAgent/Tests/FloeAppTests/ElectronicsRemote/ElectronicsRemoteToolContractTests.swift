// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeSkills
import FloeCore
import FloeModels
import FloeTools
import FloeAgentRuntime
@testable import FloeApp

@Suite("Electronics remote library tool contract")
struct ElectronicsRemoteToolContractTests {
    private func tool() -> ElectronicsRemoteTool {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("electronics-tool-test")
        return ElectronicsRemoteTool(policyStore: GitHubTransportMirrorPolicyStore(persistenceURL: nil),
            cacheRootProvider: { root },
            manifestDownload: { throw GitHubTransportManifestFailure.unavailable })
    }

    @Test("The dedicated tool accepts only documented actions and exact IDs")
    func rejectsArbitraryAuthority() throws {
        let tool = tool()
        try tool.validate(.init(action: "downloadModel", inputJSON: #"{"modelID":"model:lib-a:Resistor.step"}"#))
        try tool.validate(.init(action: "search", inputJSON: #"{"kind":"parts","libraryID":"lib-a","text":"Demo"}"#))
        for input in [
            #"{"kind":"parts","text":"Demo"}"#,
            #"{"kind":"models","url":"https://evil.invalid/x.step"}"#,
            #"{"kind":"libraries","libraryID":"lib-a"}"#,
            #"{"modelID":"https://evil.invalid/x.step"}"#,
            #"{"modelID":"model:lib-a:Resistor.step","url":"https://evil.invalid/x.step"}"#,
            #"{"libraryID":"lib-a","full2D":true}"#
        ] {
            let action = input.contains("modelID") ? "downloadModel" : input.contains("full2D") ? "download" : "search"
            #expect(throws: (any Error).self) {
                try tool.validate(.init(action: action, inputJSON: input))
            }
        }
        #expect(throws: (any Error).self) {
            try tool.validate(.init(action: "runShell", inputJSON: "{}"))
        }
        #expect(ElectronicsRemoteTool.name == "electronics.library")
        #expect(ElectronicsRemoteTool.riskLabels.contains(.networkAccess))
        #expect(ElectronicsRemoteTool.riskLabels.contains(.writesFiles))
    }

    @MainActor @Test("Actual runtime dispatch preserves bounded electronics JSON without raising ordinary tool limits")
    func runtimeDispatchKeepsCompleteBoundedCatalogueJSON() async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "models": [["id": "model:lib-a:Resistor.step", "description": String(repeating: "model-data", count: 1_000)]],
            "nextOffset": 50
        ], options: [.sortedKeys])
        let json = String(decoding: body, as: UTF8.self)
        #expect(body.count > 4_096 && body.count < 98_304)
        let arguments = try JSONSerialization.data(withJSONObject: [
            "action": "search", "inputJSON": #"{"kind":"models","limit":50}"#
        ])
        // Use the real tool descriptor and validator; only its transport/result
        // producer is injected. Owner's existing tests cover that producer.
        var runner = AnyAgentTool(tool())
        try runner.validateArguments(arguments)
        #expect(runner.descriptor.name == ElectronicsRemoteTool.name)
        runner.run = { _, _ in
            ToolExecutionOutput(summary: json, fullOutputSHA256: FloeDigest.sha256Hex(body),
                exitStatus: 0, maximumSummaryCharacters: 98_304)
        }
        let registry = ToolRunnerRegistry()
        registry.register(runner)
        let executor = CatalogToolExecutor(runners: registry)
        #expect(executor.allDescriptors.map(\.name) == [ElectronicsRemoteTool.name])
        let call = try ToolCall(id: "catalogue-json", toolName: ElectronicsRemoteTool.name,
            argumentsJSON: arguments, scope: .local)
        let context = ToolContext(runID: UUID(), toolCallID: call.id,
            cancellation: CancellationToken(), conversationID: UUID())
        let result = try await executor.execute(call, context: context)
        #expect(result.status == .ok)
        #expect(result.maximumSummaryCharacters == 98_304)
        #expect(result.outputSummary == json)
        let decoded = try #require(JSONSerialization.jsonObject(with: Data(result.outputSummary.utf8)) as? [String: Any])
        #expect(decoded["nextOffset"] as? Int == 50)
        #expect(result.outputDigest == FloeDigest.sha256Hex(body))

        // The exact-name exception must not change the ordinary 4K ceiling.
        runner.descriptor.name = "fixture.ordinary"
        registry.register(runner)
        let ordinaryCall = try ToolCall(id: "ordinary-json", toolName: runner.descriptor.name,
            argumentsJSON: arguments, scope: .local)
        let ordinaryContext = ToolContext(runID: context.runID, toolCallID: ordinaryCall.id,
            cancellation: CancellationToken(), conversationID: context.conversationID)
        let ordinary = try await executor.execute(ordinaryCall, context: ordinaryContext)
        #expect(ordinary.maximumSummaryCharacters == 4_096)
        #expect(ordinary.outputSummary == String(json.prefix(4_096)))
    }
}
#endif
