import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeProviders
import FloeSecurity
import FloeTools
import FloeTestSupport
import FloeAgentRuntime

@Suite("FloeAgentRuntime.RunOutputPipeline")
struct RunOutputPipelineTests {
    // Synthetic references exercise the real executor/runtime/persistence
    // transport. Snapshot byte integrity has its own file-store checks.
    @Test("Declared files cross the real executor and exact-run persistence", arguments: [Int32(0), Int32(17)])
    @available(macOS 15.4, iOS 26.0, *)
    func realExecutorToManifest(exitStatus: Int32) async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversations = SQLiteConversationStore(database: database)
        let store = SQLiteRunStore(database: database)
        let conversationID = UUID(), runID = UUID(), outputID = UUID()
        try await conversations.saveConversation(.init(id: conversationID,
            title: "Synthetic output pipeline", createdAt: Date(), updatedAt: Date()))
        let output = ToolArtifactReference(id: outputID,
            relativePath: "RunOutputs/\(runID.uuidString)/\(outputID.uuidString)/result.txt",
            mimeType: "text/plain", byteCount: 12, sha256: String(repeating: "a", count: 64))
        let evidence = ToolArtifactReference(id: UUID(), relativePath: "BrowserArtifacts/evidence.png",
            mimeType: "image/png", byteCount: 1, sha256: String(repeating: "b", count: 64))
        let toolName = "test.publishOutput"
        let registry = ToolRunnerRegistry()
        registry.register(AnyAgentTool(descriptor: .init(name: toolName,
            toolDescription: "Return synthetic output metadata", parametersJSON: #"{"type":"object"}"#,
            riskLabels: [], isSideEffecting: false)) { _, _ in
                .init(digesting: String(repeating: "result ", count: 900), exitStatus: exitStatus,
                      artifacts: [evidence], outputFiles: [output])
            })
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(try ToolCall(id: "publish-output", toolName: toolName,
                argumentsJSON: Data("{}".utf8), scope: .local))],
            [.textDelta(.init(text: "Synthetic final reply")), .completed(.init(stopReason: .endTurn))]
        ]
        let provider = TestFixtures.localhostProvider()
        let service = ConversationRunService(configuration: .init(
            conversationID: conversationID, provider: provider,
            model: TestFixtures.testModel(providerID: provider.id), allowedToolNames: [toolName]),
            adapter: adapter, policy: HumanApprovalPolicy(), executor: CatalogToolExecutor(runners: registry),
            conversationStore: conversations, runStore: store, runID: runID)
        try await service.start(goal: "Return the synthetic task output")
        #expect(try await store.run(id: runID)?.state == "completed")
        let events = try await store.events(runID: runID)
        let event = try #require(events.first { $0.kind == .toolResult })
        let payload = try JSONDecoder().decode([String: String].self, from: Data(event.payloadJSON.utf8))
        #expect(payload["status"] == (exitStatus == 0 ? "ok" : "failed"))
        let encoded = try #require(payload["outputFilesJSON"])
        #expect(try JSONDecoder().decode([ToolArtifactReference].self, from: Data(encoded.utf8)) == [output])
        #expect(try await RunOutputManifest.read(runID: runID, store: store) == (exitStatus == 0 ? [output] : []))
        #expect(try await RunOutputManifest.read(runID: runID, store: store, includePartial: true) == [output])
        #expect(adapter.requests.count == 2)
    }
}
