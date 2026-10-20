// FloeAgentRuntimeTests — S3-D run-output transport through the REAL
// runtime finalization, durable SQLite toolResult event and restart-side
// decoding.
//
// EXACT BOUNDARY (stated honestly): the private test executors implement
// ToolExecutor directly and return a ToolResult, so the tested chain is
// REAL RunOutputSnapshotStore.publish at the call boundary → runtime
// `finalizeToolResult` seal against the actor's run/call → AgentEvent →
// ConversationRunService completion-critical `.toolResult` payload → SQLite
// run-event read-back. This does NOT exercise the CatalogToolExecutor
// `ToolExecutionOutput → ToolResult` conversion, a registered native
// producer (e.g. document.createWord), the App-hosted Intent or any UI
// path — those require the real production tool graph and stay with the
// primary shared283 hosted acceptance. The publish step uses the genuine
// production publisher and real files, so ownership sealing and durable
// transport are proven on production code, not on a stub harness.

import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloeProviders
@testable import FloeModels
@testable import FloeSecurity
@testable import FloeTools
@testable import FloeCore
@testable import FloePersistence
import FloeTestSupport

/// Executor that performs real snapshot publication in its tool boundary.
private struct RunOutputPublishingExecutor: ToolExecutor {
    struct Plan: Sendable {
        var toolName: String
        var artifactRoot: URL
        var content: Data
        var displayName: String
        /// false: the executor returns a receipt whose ownership fields were
        /// forged by the "tool" (a foreign run) instead of publishing.
        var publishForReal: Bool
    }
    let plan: Plan

    func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        guard name == plan.toolName else { return nil }
        return ToolCatalog.Descriptor(name: name, riskLabels: [], isSideEffecting: false)
    }
    var allDescriptors: [ToolCatalog.Descriptor] { [] }

    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        let draft: RunOutputFile
        if plan.publishForReal {
            let sourceURL = plan.artifactRoot
                .appendingPathComponent("workspace")
                .appendingPathComponent(call.id + "-" + plan.displayName)
            try FileManager.default.createDirectory(
                at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try plan.content.write(to: sourceURL)
            draft = try RunOutputSnapshotStore.publish(
                RunOutputSnapshotRequest(
                    producerTool: call.toolName,
                    slot: "document",
                    commit: RunOutputCommit(
                        sourceURL: sourceURL,
                        sha256: FloeDigest.sha256Hex(plan.content),
                        byteCount: plan.content.count,
                        displayName: plan.displayName,
                        mimeType: "application/pdf",
                        uti: "com.adobe.pdf"
                    )
                ),
                using: context,
                artifactRoot: plan.artifactRoot
            )
        } else {
            // A tool-authored forgery: canonical shape for ANOTHER run.
            let foreignRun = UUID()
            let foreignID = RunOutputFile.derivedOutputID(
                runID: foreignRun, producerCallID: call.id, slot: "document"
            )
            draft = RunOutputFile(
                outputID: foreignID, slot: "document", runID: foreignRun,
                taskID: context.conversationID, environmentID: context.environmentID,
                producerCallID: call.id, producerTool: call.toolName,
                relativePath: RunOutputFile.canonicalRelativePath(
                    runID: foreignRun, outputID: foreignID, displayName: plan.displayName
                ),
                displayName: plan.displayName, mimeType: "application/pdf", uti: nil,
                byteCount: plan.content.count, sha256: FloeDigest.sha256Hex(plan.content),
                role: .userFile
            )
        }
        return ToolResult(
            callID: call.id,
            status: .ok,
            outputSummary: "saved \(plan.displayName)",
            outputDigest: "digest",
            outputFiles: [draft]
        )
    }
}

/// Executor that reports receipts on an explicitly failed call.
private struct FailedRunOutputExecutor: ToolExecutor {
    let toolName: String
    let root: URL
    func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        guard name == toolName else { return nil }
        return ToolCatalog.Descriptor(name: name, riskLabels: [], isSideEffecting: false)
    }
    var allDescriptors: [ToolCatalog.Descriptor] { [] }
    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        let file = root.appendingPathComponent("failed-\(call.id).bin")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let content = Data("partial bytes".utf8)
        try content.write(to: file)
        // Real publication — the call then fails AFTER committing work.
        let receipt = try RunOutputSnapshotStore.publish(
            RunOutputSnapshotRequest(
                producerTool: toolName, slot: "file",
                commit: RunOutputCommit(
                    sourceURL: file, sha256: FloeDigest.sha256Hex(content),
                    byteCount: content.count, displayName: "partial.bin",
                    mimeType: "application/octet-stream", uti: nil
                )
            ),
            using: context, artifactRoot: root
        )
        return ToolResult(
            callID: call.id, status: .failed,
            outputSummary: "verification failed after commit",
            outputDigest: "d", outputFiles: [receipt]
        )
    }
}

@Suite("FloeAgentRuntime.RunOutputTransport")
struct RunOutputTransportTests {

    private func makeStores() async throws -> (SQLiteConversationStore, SQLiteRunStore) {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return (SQLiteConversationStore(database: database), SQLiteRunStore(database: database))
    }

    private func payload(_ event: RunEventRecord) throws -> [String: String] {
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(event.payloadJSON.utf8)) as? [String: String]
        )
        return object
    }

    @Test("a published receipt is sealed to the run, persisted durably and verifies on disk")
    func sealedTransportPersists() async throws {
        let (conversationStore, runStore) = try await makeStores()
        let conversationID = UUID()
        try await conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "S3-D transport", createdAt: Date(), updatedAt: Date()
        ))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeRunOutputRuntime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let call = try TestFixtures.toolCall(id: "file-call", toolName: "test.publish", arguments: #"{"n":1}"#)
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(call)],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let executor = RunOutputPublishingExecutor(plan: .init(
            toolName: "test.publish", artifactRoot: root,
            content: Data("stable run bytes".utf8), displayName: "report.pdf",
            publishForReal: true
        ))
        let service = ConversationRunService(
            configuration: .init(
                conversationID: conversationID,
                provider: TestFixtures.localhostProvider(),
                model: TestFixtures.testModel(providerID: UUID()),
                environmentID: "env-authoritative"
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor,
            checkpointStore: MockCheckpointStore(),
            conversationStore: conversationStore,
            runStore: runStore
        )
        try await service.start(goal: "produce one file")

        let events = try await runStore.events(runID: service.runID)
        let toolResultEvents = events.filter { $0.kind == .toolResult }
        #expect(toolResultEvents.count == 1)
        let persisted = try payload(toolResultEvents[0])
        #expect(persisted["status"] == "ok")
        let json = try #require(persisted["outputFilesJSON"])
        let decoded = try JSONDecoder().decode([RunOutputFile].self, from: Data(json.utf8))
        #expect(decoded.count == 1)
        let receipt = decoded[0]
        // Identity fields are the runtime's own — sealed from the run, not
        // from anything the tool claimed.
        #expect(receipt.runID == service.runID)
        #expect(receipt.taskID == conversationID)
        #expect(receipt.environmentID == "env-authoritative")
        #expect(receipt.producerCallID == "file-call")
        #expect(receipt.producerTool == "test.publish")
        #expect(receipt.isCanonicalForCurrentRun)
        #expect(receipt.hasRuntimeConsistentIdentity)
        // The durable receipt references real snapshot bytes the reader can
        // verify — including after the ORIGINAL workspace file was rewritten.
        let workspaceFiles = try collectFiles(under: root.appendingPathComponent("workspace"))
        for file in workspaceFiles {
            try Data("mutated after commit".utf8).write(to: file)
        }
        #expect(RunOutputSnapshotStore.verify(receipt, artifactRoot: root)
            == .verified(url: root.appendingPathComponent(receipt.relativePath)))
        // And the snapshot bytes are the ORIGINAL run bytes, not the edit.
        if case .verified(let url) = RunOutputSnapshotStore.verify(receipt, artifactRoot: root) {
            #expect(try Data(contentsOf: url) == Data("stable run bytes".utf8))
        }
    }

    @Test("a forged foreign receipt fails the call honestly and is never persisted as success")
    func foreignReceiptIsRejected() async throws {
        let (conversationStore, runStore) = try await makeStores()
        let conversationID = UUID()
        try await conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "S3-D forgery", createdAt: Date(), updatedAt: Date()
        ))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeRunOutputForgery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let call = try TestFixtures.toolCall(id: "forged-call", toolName: "test.publish", arguments: #"{"n":1}"#)
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(call)],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let executor = RunOutputPublishingExecutor(plan: .init(
            toolName: "test.publish", artifactRoot: root,
            content: Data("forged".utf8), displayName: "claim.pdf",
            publishForReal: false
        ))
        let service = ConversationRunService(
            configuration: .init(
                conversationID: conversationID,
                provider: TestFixtures.localhostProvider(),
                model: TestFixtures.testModel(providerID: UUID())
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor,
            checkpointStore: MockCheckpointStore(),
            conversationStore: conversationStore,
            runStore: runStore
        )
        try await service.start(goal: "attempt forgery")

        let events = try await runStore.events(runID: service.runID)
        let toolResultEvents = events.filter { $0.kind == .toolResult }
        #expect(toolResultEvents.count == 1)
        let persisted = try payload(toolResultEvents[0])
        #expect(persisted["status"] == "failed")
        #expect(persisted["summary"]?.contains("Run output publication rejected") == true)
        #expect(persisted["outputFilesJSON"] == nil)
    }

    @Test("receipts on a failed call persist verbatim for the honest reader policy")
    func failedCallReceiptsPersist() async throws {
        let (conversationStore, runStore) = try await makeStores()
        let conversationID = UUID()
        try await conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "S3-D failed call", createdAt: Date(), updatedAt: Date()
        ))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeRunOutputFailed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let call = try TestFixtures.toolCall(id: "part-call", toolName: "test.partial", arguments: #"{"n":1}"#)
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(call)],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let executor = FailedRunOutputExecutor(toolName: "test.partial", root: root)
        let service = ConversationRunService(
            configuration: .init(
                conversationID: conversationID,
                provider: TestFixtures.localhostProvider(),
                model: TestFixtures.testModel(providerID: UUID())
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor,
            checkpointStore: MockCheckpointStore(),
            conversationStore: conversationStore,
            runStore: runStore
        )
        try await service.start(goal: "produce partial work")

        let events = try await runStore.events(runID: service.runID)
        let toolResultEvents = events.filter { $0.kind == .toolResult }
        #expect(toolResultEvents.count == 1)
        let persisted = try payload(toolResultEvents[0])
        #expect(persisted["status"] == "failed")
        let json = try #require(persisted["outputFilesJSON"])
        let decoded = try JSONDecoder().decode([RunOutputFile].self, from: Data(json.utf8))
        #expect(decoded.count == 1)
        #expect(decoded[0].displayName == "partial.bin")
        #expect(RunOutputSnapshotStore.verify(decoded[0], artifactRoot: root).isVerifiedOutcome)
    }
}

private extension RunOutputSnapshotVerification {
    var isVerifiedOutcome: Bool {
        if case .verified = self { return true }
        return false
    }
}

private func collectFiles(under directory: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    let urls = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
    )
    return urls
}
