#if canImport(UIKit)
import Foundation
import XCTest
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import FloeWorkspace
@testable import FloeApp

@MainActor private final class OutputImportFixture {
    let taskID = UUID()
    let callerRunID = UUID()
    let database: DatabaseManager
    let conversations: SQLiteConversationStore
    let runs: SQLiteRunStore
    let base: URL
    let workspace: URL
    var ownedRuns: Set<UUID> = []
    var tool: WorkspaceImportOutputTool { .init(conversations: conversations, runs: runs) }

    init() async throws {
        database = try DatabaseManager.inMemory()
        conversations = SQLiteConversationStore(database: database)
        runs = SQLiteRunStore(database: database)
        base = FileManager.default.temporaryDirectory.appendingPathComponent("OutputImport-" + UUID().uuidString)
        workspace = base.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try await database.migrate()
        try await conversations.saveConversation(.init(id: taskID, title: "Synthetic output import", createdAt: Date(), updatedAt: Date()))
        try await runs.saveRun(.init(id: callerRunID, conversationID: taskID, state: "running", goal: "Import", startedAt: Date()))
    }
    func close() {
        try? FileManager.default.removeItem(at: base)
        if let root = try? FloeArtifactStore.root() {
            for id in ownedRuns { try? FileManager.default.removeItem(at: root.appendingPathComponent("RunOutputs/" + id.uuidString)) }
        }
    }
    func context() -> ToolContext {
        var context = ToolContext(runID: callerRunID, toolCallID: "import-" + UUID().uuidString,
            approvalGrantID: UUID(), allowedToolNames: [WorkspaceImportOutputTool.name], workspaceRootURL: workspace,
            cancellation: CancellationToken(), conversationID: taskID,
            frozenEffectiveCatalogNames: [WorkspaceImportOutputTool.name])
        context.executionToolName = WorkspaceImportOutputTool.name
        return context
    }
    /// Real publisher, runtime seal and SQLite append; the resolver, receipt
    /// verifier and importer are never replaced by fixture implementations.
    func publish(runID: UUID? = nil, ownerID: UUID? = nil, status: String = "ok", unknown: Bool = false,
                 byteCount: Int = 37) async throws -> RunOutputFile {
        let run = runID ?? callerRunID, task = ownerID ?? taskID
        if task != taskID {
            try await conversations.saveConversation(.init(id: task, title: "Different synthetic owner", createdAt: Date(), updatedAt: Date()))
        }
        if run != callerRunID || task != taskID {
            try await runs.saveRun(.init(id: run, conversationID: task, state: "completed", goal: "Source", startedAt: Date(), endedAt: Date()))
        }
        let source = base.appendingPathComponent("source-" + UUID().uuidString + ".bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        let block = Data(repeating: 71, count: min(1 << 20, max(1, byteCount)))
        var remaining = byteCount
        while remaining > 0 {
            let count = min(remaining, block.count)
            try handle.write(contentsOf: block.prefix(count)); remaining -= count
        }
        try handle.close()
        let call = "producer-" + UUID().uuidString
        let context = ToolContext(runID: run, toolCallID: call, cancellation: CancellationToken(), conversationID: task)
        let draft = try RunOutputSnapshotStore.publish(.init(producerTool: "studio.run", slot: "synthetic-binary",
            commit: .init(sourceURL: source, sha256: FloeDigest.sha256Hex(ofFileAt: source), byteCount: byteCount,
                displayName: "output.bin", mimeType: "application/octet-stream")), using: context)
        ownedRuns.insert(run)
        guard case .sealed(let sealed) = RunOutputSnapshotStore.seal(drafts: [draft], runID: run, taskID: task,
            environmentID: nil, callID: call, toolName: "studio.run"), let receipt = sealed.first else {
            throw FloeError.internalError("Fixture native output did not seal")
        }
        let payload = ["tool": "studio.run", "id": call, "status": status, "outcomeUnknown": unknown ? "true" : "false",
            "outputFilesJSON": String(decoding: try JSONEncoder().encode([receipt]), as: UTF8.self)]
        _ = try await runs.appendEvent(runID: run, kind: .toolResult,
            payloadJSON: String(decoding: try JSONEncoder().encode(payload), as: UTF8.self))
        return receipt
    }
    func arguments(_ receipt: RunOutputFile, path: String = "Imported/output.bin") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["runID": receipt.runID.uuidString, "outputID": receipt.outputID, "path": path])
    }
    func execute(_ receipt: RunOutputFile, path: String = "Imported/output.bin", context: ToolContext? = nil) async throws -> ToolExecutionOutput {
        // Production AnyAgentTool JSON decoding/validation, actual tool and all
        // storage services run. The native fixture supplies the approved call
        // context; this test does not claim a provider/runtime approval run.
        try await AnyAgentTool(tool).run(arguments(receipt, path: path), context ?? self.context())
    }
    func mustFail(_ receipt: RunOutputFile, path: String = "blocked.bin", context: ToolContext? = nil) async {
        do { _ = try await execute(receipt, path: path, context: context); XCTFail("Import must fail before mutation") }
        catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(path).path))
    }
}

@MainActor final class NextRoundImportOutputTests: XCTestCase {
    func testCurrentRunCopiesRealSealedOutputAndKeepsSource() async throws {
        let fixture = try await OutputImportFixture(); defer { fixture.close() }
        let receipt = try await fixture.publish()
        let output = try await fixture.execute(receipt)
        let destination = fixture.workspace.appendingPathComponent("Imported/output.bin")
        XCTAssertEqual(try FloeDigest.sha256Hex(ofFileAt: destination), receipt.sha256)
        XCTAssertEqual(try Data(contentsOf: destination).count, receipt.byteCount)
        guard case .verified = RunOutputSnapshotStore.verify(receipt) else { return XCTFail("Original snapshot must remain byte-identical") }
        XCTAssertTrue(output.summary.contains("\"sourcePreserved\":true"))
        XCTAssertFalse(output.outcomeUnknown)
    }
    func testPreviousRunOfSameTaskAndChildOriginAreAllowed() async throws {
        let fixture = try await OutputImportFixture(); defer { fixture.close() }
        let receipt = try await fixture.publish(runID: UUID())
        var context = fixture.context()
        context.callOrigin = .init(kind: .delegatedChild, runID: context.runID, callID: context.toolCallID!,
            toolName: WorkspaceImportOutputTool.name, childID: UUID(), rootTaskID: fixture.taskID)
        _ = try await fixture.execute(receipt, context: context)
        XCTAssertEqual(try FloeDigest.sha256Hex(ofFileAt: fixture.workspace.appendingPathComponent("Imported/output.bin")), receipt.sha256)
    }
    func testForeignSourceTaskIsRejected() async throws {
        let fixture = try await OutputImportFixture(); defer { fixture.close() }
        let receipt = try await fixture.publish(runID: UUID(), ownerID: UUID())
        await fixture.mustFail(receipt)
    }
    func testFailedAndUnknownPersistedResultsAreRejected() async throws {
        let fixture = try await OutputImportFixture(); defer { fixture.close() }
        let failed = try await fixture.publish(status: "failed")
        await fixture.mustFail(failed)
        let unknown = try await fixture.publish(unknown: true)
        await fixture.mustFail(unknown)
    }
    func testMissingAndTamperedBytesCannotBecomeWorkspaceFiles() async throws {
        let fixture = try await OutputImportFixture(); defer { fixture.close() }
        let receipt = try await fixture.publish()
        let source = try FloeArtifactStore.root().appendingPathComponent(receipt.relativePath)
        try Data(repeating: 72, count: receipt.byteCount).write(to: source)
        await fixture.mustFail(receipt)
        try FileManager.default.removeItem(at: source)
        await fixture.mustFail(receipt)
    }
    func testSnapshotSymlinkAliasIsRejected() async throws {
        let fixture = try await OutputImportFixture(); defer { fixture.close() }
        let receipt = try await fixture.publish()
        let source = try FloeArtifactStore.root().appendingPathComponent(receipt.relativePath)
        let aliasTarget = fixture.base.appendingPathComponent("same-bytes.bin")
        try FileManager.default.copyItem(at: source, to: aliasTarget)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: aliasTarget)
        await fixture.mustFail(receipt)
    }
    func testExistingDestinationNeverOverwritesAndSourceSurvives() async throws {
        let fixture = try await OutputImportFixture(); defer { fixture.close() }
        let receipt = try await fixture.publish(), file = fixture.workspace.appendingPathComponent("kept.bin")
        try Data("user-original".utf8).write(to: file)
        do { _ = try await fixture.execute(receipt, path: "kept.bin"); XCTFail("Must preserve existing user file") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), Data("user-original".utf8))
        guard case .verified = RunOutputSnapshotStore.verify(receipt) else { return XCTFail("Source was changed") }
    }
    func testAlreadyCancelledCallAndEmptyOutputAreExplicitFailures() async throws {
        let fixture = try await OutputImportFixture(); defer { fixture.close() }
        let receipt = try await fixture.publish()
        let context = fixture.context(); context.cancellation.cancel()
        await fixture.mustFail(receipt, context: context)
        let empty = try await fixture.publish(byteCount: 0)
        await fixture.mustFail(empty)
    }
    func testLargeVerifiedBinaryUsesStreamImportWithoutRelaxingPayloadCap() async throws {
        let fixture = try await OutputImportFixture(); defer { fixture.close() }
        let receipt = try await fixture.publish(byteCount: 5 * 1024 * 1024)
        _ = try await fixture.execute(receipt)
        XCTAssertEqual(try FloeDigest.sha256Hex(ofFileAt: fixture.workspace.appendingPathComponent("Imported/output.bin")), receipt.sha256)
        let service = WorkspaceFileService(guard: .init(rootURL: fixture.workspace))
        XCTAssertThrowsError(try service.createBinaryFile("arbitrary-model.bin", data: Data(repeating: 1, count: 5 * 1024 * 1024)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("arbitrary-model.bin").path))
    }
    func testTaskCancellationDuringActualStagingRemovesOnlyOwnPartial() async throws {
        let fixture = try await OutputImportFixture(); defer { fixture.close() }
        let receipt = try await fixture.publish(byteCount: 16 * 1024 * 1024)
        let context = fixture.context(), sibling = context.cancellation.derived()
        let tool = fixture.tool, arguments = try fixture.arguments(receipt, path: "cancelled.bin")
        let operation = Task { try await AnyAgentTool(tool).run(arguments, context) }
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(8))
        var observed = false
        while clock.now < deadline {
            if (try FileManager.default.contentsOfDirectory(atPath: fixture.workspace.path)).contains(where: { $0.hasPrefix(".floe-import-") }) {
                observed = true; break
            }
            if FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("cancelled.bin").path) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(observed, "Must observe the real stream staging before exercising cancellation")
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Observed in-progress import must cancel") } catch {}
        XCTAssertFalse(context.cancellation.isCancelled, "Never cancel the parent task's token")
        XCTAssertFalse(sibling.isCancelled, "Never cancel an unrelated sibling call")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("cancelled.bin").path))
        XCTAssertFalse((try FileManager.default.contentsOfDirectory(atPath: fixture.workspace.path)).contains(where: { $0.hasPrefix(".floe-import-") }))
        guard case .verified = RunOutputSnapshotStore.verify(receipt) else { return XCTFail("Source must remain valid") }
    }
    func testTemporaryWebOnlyDeniedCatalogAndForeignChildContextsCannotImport() async throws {
        let fixture = try await OutputImportFixture(); defer { fixture.close() }
        let receipt = try await fixture.publish()
        var context = fixture.context(); context.temporaryReadOnly = true
        await fixture.mustFail(receipt, context: context)
        context = fixture.context(); context.publicWebOnly = true
        await fixture.mustFail(receipt, context: context)
        context = fixture.context(); context.allowedToolNames = []
        await fixture.mustFail(receipt, context: context)
        context = fixture.context(); context.frozenEffectiveCatalogNames = []
        await fixture.mustFail(receipt, context: context)
        context = fixture.context(); context.scope = .host(UUID())
        await fixture.mustFail(receipt, context: context)
        context = fixture.context(); context.callOrigin = .init(kind: .delegatedChild, runID: context.runID,
            callID: context.toolCallID!, toolName: WorkspaceImportOutputTool.name, childID: UUID(), rootTaskID: UUID())
        await fixture.mustFail(receipt, context: context)
        context = fixture.context(); context.approvalGrantID = nil
        await fixture.mustFail(receipt, context: context)
        context = fixture.context(); context.executionToolName = "unrelated.wrapper"
        await fixture.mustFail(receipt, context: context)
        let loadedConversation = try await fixture.conversations.conversation(id: fixture.taskID)
        var conversation = try XCTUnwrap(loadedConversation)
        conversation.purpose = .temporary
        // Real temporary conversations are RAM-only. The SQLite domain is
        // deliberately ordinary/notes, so persisting temporary must fail.
        do {
            try await fixture.conversations.saveConversation(conversation)
            XCTFail("Temporary conversations must never be persisted")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
            XCTAssertEqual(error.extendedResultCode, .SQLITE_CONSTRAINT_CHECK)
        }
        let persisted = try await fixture.conversations.conversation(id: fixture.taskID)
        XCTAssertEqual(persisted?.purpose, .ordinary, "Failed persistence must preserve the original conversation")
        context = fixture.context(); context.temporaryReadOnly = true
        await fixture.mustFail(receipt, context: context)
    }
    func testMissingExplicitWorkspaceAndFileCeilingNeverUseGlobalFallback() async throws {
        let fixture = try await OutputImportFixture(); defer { fixture.close() }
        let receipt = try await fixture.publish()
        var context = fixture.context(); context.workspaceRootURL = nil
        await fixture.mustFail(receipt, context: context)
        context = fixture.context(); context.allowedWorkspacePaths = ["Allowed"]
        await fixture.mustFail(receipt, path: "outside.bin", context: context)
        await fixture.mustFail(receipt, path: "../escape.bin")
        await fixture.mustFail(receipt, path: "Network/test/output.bin")
    }
    func testModelSourcePathReceiptAndDigestOverridesAreNotAccepted() async throws {
        let fixture = try await OutputImportFixture(); defer { fixture.close() }
        let receipt = try await fixture.publish()
        for key in ["sourcePath", "sha256", "receipt", "artifactRoot"] {
            let data = try JSONSerialization.data(withJSONObject: ["runID": receipt.runID.uuidString,
                "outputID": receipt.outputID, "path": "forged.bin", key: "model-supplied"])
            do { _ = try await AnyAgentTool(fixture.tool).run(data, fixture.context()); XCTFail("Reject extra source authority field") } catch {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("forged.bin").path))
    }
    func testProductionRegistrationExposesExactNonExecutingSchema() async throws {
        let fixture = try await OutputImportFixture(); defer { fixture.close() }
        let registry = ToolRunnerRegistry()
        registerWorkspaceImportOutputTool(conversations: fixture.conversations, runs: fixture.runs, registry: registry)
        let runner = try XCTUnwrap(registry.runner(named: "workspace.importOutput"))
        XCTAssertTrue(runner.descriptor.isSideEffecting)
        XCTAssertEqual(runner.descriptor.riskLabels, [.readsFiles, .writesFiles])
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(runner.descriptor.parametersJSON.utf8)) as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(schema["required"] as? [String])), ["runID", "outputID", "path"])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set(try XCTUnwrap(schema["properties"] as? [String: Any]).keys), ["runID", "outputID", "path"])
    }
}
#endif
