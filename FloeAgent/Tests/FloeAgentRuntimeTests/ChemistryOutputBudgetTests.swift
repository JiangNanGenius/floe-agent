// FloeAgentRuntimeTests — action-specific structured-result budget.
//
// studio.chemistry.environment returns canonical pendingJobs JSON whose
// jobs.submit arguments carry the frozen shellPayload/receipt contract. Some
// stages (probe capability maps, multi-job receipts) can exceed the generic
// 4096-character UI summary. A second, action-agnostic cut in the catalog
// executor produced invalid partial JSON and made the real machine contract
// unreadable. Long structured studio pages already use the existing bounded
// 196_608-character group; this test locks the native chemistry environment
// name into that same bound without raising the ordinary default.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeTools
@testable import FloeAgentRuntime

@Suite("FloeAgentRuntime.ChemistryOutputBudget")
struct ChemistryOutputBudgetTests {
    private static func context() -> ToolContext {
        ToolContext(runID: UUID(), cancellation: CancellationToken())
    }

    private static func executor(summary: String, toolMaximum: Int) -> CatalogToolExecutor {
        let registry = ToolRunnerRegistry()
        let descriptor = ToolCatalog.Descriptor(
            name: "studio.chemistry.environment",
            toolDescription: "Prepare a real chemistry job",
            parametersJSON: #"{"type":"object"}"#,
            riskLabels: [],
            isSideEffecting: true
        )
        registry.register(AnyAgentTool(descriptor: descriptor) { _, _ in
            .init(
                summary: summary,
                fullOutputSHA256: "",
                maximumSummaryCharacters: toolMaximum
            )
        })
        return CatalogToolExecutor(runners: registry)
    }

    @Test("A complete pendingJobs contract above 4096 survives the catalog boundary")
    func pendingJobsContractIsNotCutAtFourK() async throws {
        let shellPayload = String(repeating: "python3 transport.py --manifest abc; ", count: 210)
        let jobArguments: [String: Any] = [
            "tool": "exec.shell",
            "arguments": #"{"command":"\#(shellPayload)","cwd":".","maxOutputBytes":32768}"#,
            "purpose": "probe",
            "wait": true
        ]
        let jobArgumentsJSON = String(
            decoding: try JSONSerialization.data(withJSONObject: jobArguments, options: [.sortedKeys]),
            as: UTF8.self
        )
        let summary = String(
            decoding: try JSONSerialization.data(withJSONObject: [
                "attemptID": "11111111-1111-1111-1111-111111111111",
                "state": "awaitingSubmission",
                "pendingJobs": [["tool": "jobs.submit", "arguments": jobArgumentsJSON]]
            ], options: [.sortedKeys]),
            as: UTF8.self
        )
        #expect(summary.utf8.count > 4096)

        let call = try ToolCall(
            id: "chemistry-environment",
            toolName: "studio.chemistry.environment",
            argumentsJSON: Data(#"{"projectID":"11111111-1111-1111-1111-111111111111","action":"probe"}"#.utf8),
            scope: .local
        )
        let result = try await Self.executor(summary: summary, toolMaximum: 96 * 1024)
            .execute(call, context: Self.context())

        #expect(result.outputSummary == summary)
        #expect(!result.capturedOutputTruncated)
        #expect(result.capturedOutput == summary)
        let parsed = try JSONSerialization.jsonObject(with: Data(result.outputSummary.utf8))
        let object = try #require(parsed as? [String: Any])
        let jobs = try #require(object["pendingJobs"] as? [[String: Any]])
        #expect(jobs.count == 1)
        #expect((jobs.first?["arguments"] as? String)?.contains("transport.py") == true)
    }

    @Test("A synthetic page above the bound is cut but retains the full captured bytes")
    func syntheticOversizeRetainsCapturedBytes() async throws {
        let summary = String(repeating: "x", count: 200_000)
        let call = try ToolCall(
            id: "chemistry-environment-oversized",
            toolName: "studio.chemistry.environment",
            argumentsJSON: Data(#"{"projectID":"11111111-1111-1111-1111-111111111111","action":"probe"}"#.utf8),
            scope: .local
        )
        let result = try await Self.executor(summary: summary, toolMaximum: 262_144)
            .execute(call, context: Self.context())

        #expect(result.outputSummary.utf8.count == 196_608)
        // The full producer page is still retained transiently for capture /
        // provider budgeting; only the model-visible projection is bounded.
        #expect(result.capturedOutput == summary)
        // Real studio pages are rejected by the producer at 96 KiB, which is
        // below this executor bound, so a real chemistry result cannot reach
        // this synthetic truncation path. If a future producer raises its own
        // page size, this test documents that the full bytes remain retained
        // for capture rather than being silently lost.
    }
}
