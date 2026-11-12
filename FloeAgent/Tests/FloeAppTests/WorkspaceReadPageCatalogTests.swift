// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloeTools
import FloeWorkspace
import FloeAgentRuntime

@Suite("FloeApp.WorkspaceReadPageCatalog")
struct WorkspaceReadPageCatalogTests {
    @Test("A real native text page survives CatalogToolExecutor and durable ToolResult coding without a second 4k cut")
    func completeWorkspacePageSurvivesCatalogAndCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-catalog-page-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = String(repeating: "\u{6c49}\u{1f642}", count: 50_000)
        try text.write(to: root.appendingPathComponent("large.txt"), atomically: true, encoding: .utf8)
        let runners = ToolRunnerRegistry()
        registerWorkspaceTools(rootProvider: { root }, registry: runners)
        let context = ToolContext(runID: UUID(), workspaceRootURL: root, cancellation: CancellationToken())
        let call = try ToolCall(id: "read-page", toolName: "workspace.readFile",
            argumentsJSON: Data(#"{"path":"large.txt"}"#.utf8), scope: .local)
        let result = try await CatalogToolExecutor(runners: runners).execute(call, context: context)
        #expect(result.status == .ok)
        #expect(result.outputSummary.count > 4_096)
        let parts = result.outputSummary.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        #expect(parts.count == 2)
        let header = try #require(parts.first)
        let nextField = try #require(header.split(separator: " ").first { $0.hasPrefix("nextOffset=") })
        let next = try #require(Int(nextField.dropFirst("nextOffset=".count)))
        let content = parts.count == 2 ? String(parts[1]) : ""
        #expect(content.utf8.count == next)
        #expect(Data(content.utf8) == Data(text.utf8.prefix(next)))
        let stored = try JSONEncoder().encode(result)
        let restored = try JSONDecoder().decode(ToolResult.self, from: stored)
        #expect(restored.outputSummary == result.outputSummary)
        #expect(restored.maximumSummaryCharacters == 196_608)
        #expect(restored.outputDigest == result.outputDigest)
    }
}
#endif
