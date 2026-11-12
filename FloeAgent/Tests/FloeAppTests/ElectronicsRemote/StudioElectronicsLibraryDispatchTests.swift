// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && DEBUG
import Foundation
import Testing
import FloeCore
import FloeModels
import FloeTools
import FloeAgentRuntime
@testable import FloeApp

private actor ElectronicsLibraryDispatchWitness {
    private var actions: [String] = []
    func accept(_ action: String) { actions.append(action) }
    func accepted() -> [String] { actions }
}

@Suite("Registered electronics library dispatch", .serialized)
@MainActor struct StudioElectronicsLibraryDispatchTests {
    @Test("All six native library actions pass the production studio.run validator")
    func allLibraryActionsReachDispatchAndUnknownActionIsRejected() async throws {
        _ = try await appQualificationEnvironment()
        let registered = try #require(ToolRunnerRegistry.shared.runner(named: "studio.run"))
        let expected = ["eda.library.search", "eda.library.read", "eda.library.bind",
                        "eda.library.place", "eda.library.previewReplace", "eda.library.replace"]
        #expect(Set(StudioElectronicsLibraryContract.actions) == Set(expected))
        let validate = registered.validateArguments
        let witness = ElectronicsLibraryDispatchWitness()
        var boundary = registered
        // Retain the actual registered descriptor and typed validator. Replace
        // only downstream document effects: this regression targets the guard
        // that rejected valid library calls before reaching their native host.
        boundary.run = { arguments, _ in
            try validate(arguments)
            let object = try JSONSerialization.jsonObject(with: arguments) as? [String: Any]
            let action = try #require(object?["action"] as? String)
            await witness.accept(action)
            return ToolExecutionOutput(summary: action,
                fullOutputSHA256: FloeDigest.sha256Hex(Data(action.utf8)), exitStatus: 0)
        }
        let registry = ToolRunnerRegistry()
        registry.register(boundary)
        let executor = CatalogToolExecutor(runners: registry)
        let projectID = UUID(), runID = UUID(), conversationID = UUID()
        for action in expected + ["eda.library.unknown"] {
            let arguments = try JSONSerialization.data(withJSONObject: [
                "projectID": projectID.uuidString, "action": action, "inputJSON": "{}"
            ])
            let call = try ToolCall(id: action, toolName: "studio.run",
                                    argumentsJSON: arguments, scope: .local)
            let context = ToolContext(runID: runID, toolCallID: call.id,
                cancellation: CancellationToken(), conversationID: conversationID)
            let result = try await executor.execute(call, context: context)
            if action == "eda.library.unknown" {
                #expect(throws: (any Error).self) { try registered.validateArguments(arguments) }
                #expect(result.status == .failed)
                #expect(result.outputSummary.contains("Unsupported native operation"))
            } else {
                try registered.validateArguments(arguments)
                #expect(result.status == .ok)
                #expect(result.outputSummary == action)
            }
        }
        #expect(await witness.accepted() == expected)
    }
}
#endif
