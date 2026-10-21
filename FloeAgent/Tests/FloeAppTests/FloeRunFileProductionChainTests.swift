// App-host qualification for the production run-file chain.
// Execution evidence is recorded separately from source registration.
// The provider is scripted; document creation, Catalog conversion, runtime,
// SQLite persistence, exact-run service and Intent execution are production.
// No tool result, receipt, assistant row or terminal marker is hand-seeded.
#if canImport(AppIntents) && DEBUG
import XCTest
import AppIntents
import UniformTypeIdentifiers
import ZIPFoundation
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloeSecurity
import FloeAgentRuntime
import FloePersistence
import FloeEnvironments
import FloeDocuments
import FloeTestSupport
@testable import FloeApp

@MainActor
final class FloeRunFileProductionChainTests: XCTestCase {
    func testNativeWordThroughCatalogRuntimeSQLiteAndFilesIntent() async throws {
        // Tool execution resolves its environment through the process-wide
        // routing the real app factory installs. Build the preview factory so
        // this test installs exactly the routing it exercises instead of
        // depending on another test's global setup.
        let environment = AppEnvironment.preview()
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversations = SQLiteConversationStore(database: database)
        let runs = SQLiteRunStore(database: database)
        let conversationID = UUID()
        let runID = UUID()
        let marker = "Verified native file chain " + UUID().uuidString
        try await conversations.saveConversation(.init(
            id: conversationID, title: "File chain qualification",
            createdAt: Date(), updatedAt: Date()))

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeNativeFileChain-" + UUID().uuidString,
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let artifactRoot = try FloeArtifactStore.root()
        let ownedRunDirectory = artifactRoot
            .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedRunDirectory.path))
        defer { try? FileManager.default.removeItem(at: ownedRunDirectory) }

        // Register this run's OWN session container through the production
        // run-binding path. It is owned by exactly this conversation and this
        // workspace root, so it is the only legitimate explicit environment
        // binding for the run — never a guessed id, another task's container
        // or a first-project/temporary fallback.
        let boundEnvironmentID = await ConversationCenter.ensureRunEnvironmentBinding(
            registry: environment.environmentRegistry,
            conversationID: conversationID,
            taskRoot: workspace)
        let environmentID = try XCTUnwrap(
            boundEnvironmentID,
            "the preview environment must register this task's own session container")

        // Await cleanup on success AND failure without capturing the preview
        // app object; only this registry actor and the exact owned IDs escape.
        let ownedRegistry = environment.environmentRegistry
        let registeredWorkspaceID = FloeDigest.sha256Hex(Data(
            workspace.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
        addTeardownBlock {
            _ = try? await ownedRegistry.remove(id: environmentID)
            let projectContainers = await ownedRegistry
                .containersOwned(by: registeredWorkspaceID)
            if let project = projectContainers.first(where: { $0.kind == .project }) {
                _ = try? await ownedRegistry.remove(id: project.id)
            }
        }

        let registry = ToolRunnerRegistry()
        registry.register(DocumentCreateWordTool(rootProvider: { workspace }))
        let executor = CatalogToolExecutor(runners: registry)
        let call = try ToolCall(
            id: "create-native-word", toolName: DocumentCreateWordTool.name,
            argumentsJSON: JSONSerialization.data(withJSONObject: [
                "path": "chain.docx", "title": "Chain", "paragraphs": [marker]
            ]), scope: .local)
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(call)],
            [.textDelta(.init(text: "Created the verified document.")),
             .completed(.init(stopReason: .endTurn))]
        ]
        let provider = TestFixtures.localhostProvider()
        let runtimeService = ConversationRunService(
            configuration: .init(
                conversationID: conversationID, provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                allowedToolNames: [DocumentCreateWordTool.name],
                workspaceRootURL: workspace, pauseTimeout: 0.2,
                environmentID: environmentID),
            adapter: adapter, policy: HumanApprovalPolicy(), executor: executor,
            checkpointStore: MockCheckpointStore(),
            conversationStore: conversations, runStore: runs, runID: runID)
        try await runtimeService.start(goal: "Create chain.docx with the supplied marker.")

        let events = try await runs.events(runID: runID)
        let resultEvents = events.filter { $0.kind == .toolResult }
        XCTAssertEqual(resultEvents.count, 1)
        let resultEvent = try XCTUnwrap(resultEvents.first)
        let payload = try JSONDecoder().decode(
            [String: String].self, from: Data(resultEvent.payloadJSON.utf8))
        XCTAssertEqual(payload["status"], "ok", payload["summary"] ?? resultEvent.payloadJSON)
        let encodedReceipts = try XCTUnwrap(payload["outputFilesJSON"])
        let receipts = try JSONDecoder().decode(
            [RunOutputFile].self, from: Data(encodedReceipts.utf8))
        XCTAssertEqual(receipts.count, 1)
        let receipt = try XCTUnwrap(receipts.first)
        XCTAssertEqual(receipt.runID, runID)
        XCTAssertEqual(receipt.taskID, conversationID)
        XCTAssertEqual(receipt.environmentID, environmentID)
        XCTAssertEqual(receipt.producerCallID, call.id)
        XCTAssertEqual(receipt.producerTool, DocumentCreateWordTool.name)
        XCTAssertTrue(receipt.hasRuntimeConsistentIdentity)

        let original = workspace.appendingPathComponent("chain.docx")
        let expectedBytes = try Data(contentsOf: original)
        XCTAssertEqual(receipt.sha256, FloeDigest.sha256Hex(expectedBytes))
        XCTAssertEqual(receipt.byteCount, expectedBytes.count)
        let archive = try Archive(url: original, accessMode: .read)
        let documentXML = try XCTUnwrap(archive["word/document.xml"])
        var xmlBytes = Data()
        _ = try archive.extract(documentXML) { xmlBytes.append($0) }
        XCTAssertTrue(String(decoding: xmlBytes, as: UTF8.self).contains(marker))

        let outputReader = SQLiteRunOutputReader(database: database)
        let replyReader = SQLiteRunReplyReader(database: database)
        let exactService = FloeShortcutRunService(deps: .init(
            ensureReady: { _ in }, capabilityEnabled: { true }, defaultModel: { nil },
            startTask: { _ in throw FloeShortcutRunError.noDefaultModelConfigured },
            cancelRun: { _ in }, hasLiveOwner: { _ in false },
            loadRun: { try await runs.run(id: $0) },
            loadConversation: { try await conversations.conversation(id: $0) },
            recentRunEvents: { try await runs.recentEvents(runID: $0, limit: $1) },
            earlierRunEvents: { try await runs.earlierEvents(runID: $0, beforeSequence: $1, limit: $2) },
            provenFinalReplyText: {
                try await replyReader.provenFinalReplyText(runID: $0, conversationID: $1, messageID: $2)
            },
            runOutputManifest: {
                try await outputReader.manifestRows(runID: $0, expectedConversationID: $1)
            },
            verifyRunOutputSnapshot: { RunOutputSnapshotStore.verify($0) }))

        // The source can change and disappear before the shortcut retrieves
        // the result. Only the immutable published snapshot may be returned.
        try Data("later workspace edit".utf8).write(to: original)
        try FileManager.default.removeItem(at: original)
        var intent = GetFloeRunFilesIntent()
        intent.run = FloeShortcutRunEntity(
            runID: runID, conversationID: conversationID,
            title: "File chain qualification", state: .running,
            isFinished: false, isSuccessful: false, requiresUserAction: false)
        intent.includePartial = false
        let response = try await FloeShortcutRunIntentBridge.$debugService.withValue(exactService) {
            try await intent.perform()
        }
        let files = try XCTUnwrap(response.value)
        XCTAssertEqual(files.count, 1)
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(file.filename, "chain.docx")
        XCTAssertEqual(file.type, UTType("org.openxmlformats.wordprocessingml.document"))
        XCTAssertFalse(file.removedOnCompletion)
        let delivered = try XCTUnwrap(file.fileURL)
        XCTAssertEqual(delivered.standardizedFileURL.resolvingSymlinksInPath(),
                       artifactRoot.appendingPathComponent(receipt.relativePath)
                        .standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(try Data(contentsOf: delivered), expectedBytes)
        XCTAssertEqual(try FloeDigest.sha256Hex(ofFileAt: delivered), receipt.sha256)
    }
}
#endif
