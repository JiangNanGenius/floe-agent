// SPDX-License-Identifier: MPL-2.0
// Real App service and persistence contract using the Settings-owned original.
// Provider transport is scripted; UI and physical installation remain separate.
// Only provider transport is scripted. No runner registration, approval grant,
// RuntimeTaskAuthority, tool result or RunOutputFile is seeded by this test.
#if canImport(UIKit) && DEBUG
import XCTest
import Foundation
import CoreText
import Darwin
import FloeCore
import FloeModels
import FloeTools
import FloeSecurity
import FloeAgentRuntime
import FloePersistence
import FloeHeavyEditorSupport
import FloeTestSupport
@testable import FloeApp

@MainActor final class FontDesignAIAppContractTests: XCTestCase {
    func testDraftDeletionRemovesOnlyOwnedDraftAndExports() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("font-library-delete-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = FontDesignLibrary(rootURL: root.appendingPathComponent("Library"))
        // This fixture exercises file ownership, not font compilation.
        let sourceData = Data("original-font-input".utf8), sourceID = FontDesignLibrary.digest(sourceData)
        let external = root.appendingPathComponent("Installed.ttf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try sourceData.write(to: external)
        let source = FontDesignManagedSource(record: .init(id: sourceID, fileName: sourceID + ".ttf",
            displayName: "Original", familyNames: ["Original"], postScriptNames: ["Original"], byteCount: Int64(sourceData.count)), data: sourceData)
        let project = try await library.create(source: source), other = try await library.create()
        let directory = try await library.directory(for: project.id)
        _ = try await library.export(designID: project.id, sourceRevision: project.revision,
            artifact: HeavyEditorArtifact(name: "preview.svg", mediaType: "image/svg+xml", data: Data("<svg/>".utf8)))
        let intent = try await library.stageDeletion(project, assistantID: nil)
        try await library.finishDeletion(intent)
        let listed = try await library.list()
        XCTAssertEqual(listed.map(\.id), [other.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try Data(contentsOf: external), sourceData)
        let pending = try await library.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
        let reopened = FontDesignLibrary(rootURL: root.appendingPathComponent("Library"))
        let reopenedProjects = try await reopened.list(), reopenedPending = try await reopened.pendingDeletions()
        XCTAssertEqual(reopenedProjects.map(\.id), [other.id])
        XCTAssertTrue(reopenedPending.isEmpty)
    }

    func testDraftDeletionRejectsOpenEditorAndChangedRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("font-library-cas-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = FontDesignLibrary(rootURL: root)
        let project = try await library.create()
        let token = try await library.retainPresentation(project.id)
        do { _ = try await library.stageDeletion(project, assistantID: nil); XCTFail("An open editor was deleted") }
        catch FontDesignError.editorOpen { }
        await library.releasePresentation(token)
        let store = try HeavyEditorProjectStore(directory: await library.directory(for: project.id), documentID: project.id, kind: .font)
        let current = try await store.read()
        _ = try await store.commit(content: current.content, expectedRevision: current.revision)
        do { _ = try await library.stageDeletion(project, assistantID: nil); XCTFail("A changed original was deleted") }
        catch HeavyEditorError.revisionConflict { }
        let retained = try await library.project(project.id)
        XCTAssertEqual(retained.revision, 1)
        let pending = try await library.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
    }

    func testDraftDeletionDoesNotWaitForAnExistingSaveLock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("font-library-save-lock-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = FontDesignLibrary(rootURL: root), project = try await library.create()
        let directory = try await library.directory(for: project.id)
        let fd = Darwin.open(directory.appendingPathComponent(".document.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { _ = flock(fd, LOCK_UN); Darwin.close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        do { _ = try await library.stageDeletion(project, assistantID: nil); XCTFail("Deletion ignored an active save") }
        catch FontDesignError.saving { }
        let pending = try await library.pendingDeletions()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testDraftDeletionRecoversIntentAndRejectsLateCreationAndSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("font-library-recover-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = FontDesignLibrary(rootURL: root)
        let authority = try StudioDocumentAccess(root: root.appendingPathComponent("TaskAuthority"))
        let operation = "font-delete-replay-" + UUID().uuidString
        let id = try await authority.reserveCreation(operationKey: operation, digest: "test-payload")
        let project = try await library.createForTask(id: id, title: "Replay fixture", authorize: {})
        let oldDirectory = try await library.directory(for: id)
        let oldStore = try HeavyEditorProjectStore(directory: oldDirectory, documentID: id, kind: .font)
        let oldDocument = try await oldStore.read()
        let intent = try await library.stageDeletion(project, assistantID: nil)
        // Crash injection: intent is durable, but the directory move has not
        // committed yet. A fresh service must resume that exact deletion.
        try FileManager.default.moveItem(at: root.appendingPathComponent("Deletions/" + id.uuidString + "/Project"), to: oldDirectory)
        let reopened = FontDesignLibrary(rootURL: root)
        let pending = try await reopened.pendingDeletions()
        XCTAssertEqual(pending, [intent])
        try await authority.revokeDeletedFontAuthority(projectID: id)
        try await reopened.finishDeletion(intent)
        let reservedAfterDeletion = try await authority.reserveCreation(operationKey: operation, digest: "test-payload")
        XCTAssertEqual(reservedAfterDeletion, id)
        do { _ = try await reopened.createForTask(id: id, title: "Replay fixture", authorize: {}); XCTFail("Late create revived a deleted draft") }
        catch FontDesignError.invalidProject { }
        do { _ = try await oldStore.commit(content: oldDocument.content, expectedRevision: oldDocument.revision); XCTFail("Late save revived a deleted draft") }
        catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDirectory.path))
        let listed = try await reopened.list()
        XCTAssertTrue(listed.isEmpty)
    }

    func testFontAssistantDeletionPurgesOnlyItsBoundConversationAndGrants() async throws {
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        let library = FontDesignLibrary.shared
        let project = try await library.create()
        let assistant = try await environment.fontDesignAIHost.assistant(for: project.id)
        let preservedFonts = await environment.fontStore.list()
        try await environment.fontDesignAIHost.removeDesign(project)
        let deletedConversation = try await environment.conversationStore.conversation(id: assistant)
        XCTAssertNil(deletedConversation)
        let access = try StudioDocumentAccess(root: await library.taskAuthorityDirectory())
        let deletedBinding = try await access.assistant(projectID: project.id)
        let staleAccess = try await access.canAccess(conversationID: assistant, projectID: project.id, editing: false)
        let fontsAfterDeletion = await environment.fontStore.list()
        let projectsAfterDeletion = try await library.list()
        XCTAssertNil(deletedBinding)
        XCTAssertFalse(staleAccess)
        XCTAssertEqual(fontsAfterDeletion, preservedFonts)
        XCTAssertFalse(projectsAfterDeletion.contains { $0.id == project.id })
    }

    func testBatchDeletionSkipsIncludedFontsAndRetainsFailedOrUnselectedDrafts() async throws {
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        let library = FontDesignLibrary.shared
        let removable = try await library.create(), busy = try await library.create(), untouched = try await library.create()
        let busyToken = try await library.retainPresentation(busy.id)
        let result = await FontManagementRemovalService.remove([.design(removable.id), .design(busy.id), .bundled("MiSans")],
            projects: [removable, busy, untouched], fonts: [], store: environment.fontStore, host: environment.fontDesignAIHost)
        XCTAssertEqual(result.removed, [.design(removable.id)])
        XCTAssertEqual(result.failures.map(\.item), [.design(busy.id)])
        let retainedBusy = try await library.project(busy.id), retainedOther = try await library.project(untouched.id)
        XCTAssertEqual(retainedBusy, busy)
        XCTAssertEqual(retainedOther, untouched)
        await library.releasePresentation(busyToken)
        try await environment.fontDesignAIHost.removeDesign(busy)
        try await environment.fontDesignAIHost.removeDesign(untouched)
    }

    private func call(_ id: String, _ tool: String, _ arguments: EditorJSON) throws -> ToolCall {
        try ToolCall(id: id, toolName: tool, argumentsJSON: arguments.data(), scope: .local)
    }
    private func runScript(environment: AppEnvironment, task: UUID, run: UUID,
                           stores: [String: String], calls: [ToolCall]) async throws {
        let adapter = MockAdapter()
        adapter.script = calls.map { [.toolRequest($0), .completed(.init(stopReason: .toolUse))] }
            + [[.textDelta(.init(text: "Font service contract finished.")), .completed(.init(stopReason: .endTurn))]]
        let provider = TestFixtures.localhostProvider()
        // Same real metadata-only context pattern as ConversationCenter. It
        // carries native roots and no execution name/grant/runtime authority.
        let metadata = ToolContext(runID: run, allowedToolNames: FontDesignAIHost.names,
            serviceStorePaths: stores, cancellation: CancellationToken(), conversationID: task)
        let service = ConversationRunService(configuration: .init(conversationID: task, provider: provider,
            model: TestFixtures.testModel(providerID: provider.id), allowedToolNames: FontDesignAIHost.names,
            pauseTimeout: 0.5, verifyFinalAnswer: false, maxProviderRetries: 0, serviceStorePaths: stores,
            currentToolAvailability: { [weak environment] in
                guard let environment else { return [] }
                do { return Set(try await environment.heavyEditorAppTools.descriptors(for: metadata).map(\.name)) }
                catch { return [] }
            }), adapter: adapter, policy: AutomaticApprovalPolicy(), executor: CatalogToolExecutor(),
            conversationStore: environment.conversationStore, runStore: environment.runStore, runID: run)
        try await service.start(goal: "Run only this synthetic typeface's native editor contract; export files without installing a font.")
        let saved = try await environment.runStore.run(id: run)
        XCTAssertEqual(saved?.state, "completed")
        let events = try await environment.runStore.events(runID: run)
        let results = try events.filter { $0.kind == .toolResult }.map {
            try JSONDecoder().decode([String: String].self, from: Data($0.payloadJSON.utf8))
        }
        for call in calls {
            let result = try XCTUnwrap(results.first { $0["id"] == call.id }, "Missing real persisted toolResult for \(call.toolName)")
            XCTAssertEqual(result["tool"], call.toolName)
            XCTAssertEqual(result["status"], "ok", result["summary"] ?? "missing tool result summary")
        }
        XCTAssertEqual(adapter.requests.count, calls.count + 1)
    }
    private func output(environment: AppEnvironment, task: UUID, run: UUID, callID: String) async throws -> RunOutputFile {
        let rows = try await SQLiteRunOutputReader(database: environment.database)
            .manifestRows(runID: run, expectedConversationID: task)
        let row = try XCTUnwrap(rows.first { $0.callID == callID })
        XCTAssertEqual(row.status, "ok")
        XCTAssertEqual(row.tool, "font.export")
        let receipt = try XCTUnwrap(row.receipts.first)
        XCTAssertEqual(row.receipts.count, 1)
        XCTAssertEqual(receipt.runID, run)
        XCTAssertEqual(receipt.taskID, task)
        XCTAssertEqual(receipt.producerCallID, callID)
        XCTAssertEqual(receipt.producerTool, "font.export")
        XCTAssertTrue(receipt.hasRuntimeConsistentIdentity)
        return receipt
    }
    private func verifiedURL(_ receipt: RunOutputFile) throws -> URL {
        guard case .verified(let url) = RunOutputSnapshotStore.verify(receipt) else {
            XCTFail("The production receipt does not resolve to its actual immutable snapshot")
            throw FontDesignError.invalidOutput
        }
        return url
    }

    func testSettingsTaskRegisteredExportAndCanonicalOutputReimport() async throws {
        let environment = FloeAgentApp.liveEnvironment
        try await environment.ensureDurableAutomationReady()
        // Check Main's actual composition. Do not register replacement closures.
        for name in FontDesignAIHost.names {
            let runner = try XCTUnwrap(ToolRunnerRegistry.shared.runner(named: name), "App composition did not register \(name)")
            XCTAssertEqual(runner.descriptor.executionBoundary, .mainRunOnly)
        }
        let library = FontDesignLibrary.shared
        let project = try await library.create()
        let task = try await environment.fontDesignAIHost.assistant(for: project.id)
        let reboundTask = try await environment.fontDesignAIHost.assistant(for: project.id)
        XCTAssertEqual(task, reboundTask)
        let conversation = try await environment.conversationStore.conversation(id: task)
        XCTAssertEqual(conversation?.purpose, .ordinary)
        let authority = try StudioDocumentAccess(root: await library.taskAuthorityDirectory())
        let canEdit = try await authority.canAccess(conversationID: task, projectID: project.id, editing: true)
        let strangerCanRead = try await authority.canAccess(conversationID: UUID(), projectID: project.id, editing: false)
        XCTAssertTrue(canEdit)
        XCTAssertFalse(strangerCanRead)
        let spaceRecords = try await PersonalContentService.shared.library().records()
        XCTAssertFalse(spaceRecords.contains { $0.id == project.id }, "A typeface draft became a Space record")

        var stores = try await environment.fontDesignAIHost.typedServiceStorePaths()
        let personal = try await PersonalContentService.shared.library()
        stores.merge(await personal.typedServiceStorePaths()) { _, actual in actual }
        let firstRun = UUID(), exportCall = "font-contract-export-" + UUID().uuidString
        let projectID: EditorJSON = .string(project.id.uuidString)
        let firstCalls = try [
            call("font-contract-index", "font.describe", .object([:])),
            call("font-contract-sample", "font.invoke", .object(["projectID": projectID, "baseRevision": .number(0), "command": .string("project.sample")])),
            call("font-contract-width", "font.invoke", .object(["projectID": projectID, "baseRevision": .number(1), "command": .string("metrics.edit"),
                "arguments": .object(["glyph": .string("A"), "advance": .number(725), "left": .number(20), "right": .string("")])])),
            call(exportCall, "font.export", .object(["projectID": projectID, "baseRevision": .number(2), "command": .string("file.export"),
                "arguments": .object(["format": .string("ttf"), "instance": .bool(false)])]))
        ]
        try await runScript(environment: environment, task: task, run: firstRun, stores: stores, calls: firstCalls)
        let firstOutput = try await output(environment: environment, task: task, run: firstRun, callID: exportCall)
        let firstURL = try verifiedURL(firstOutput), firstBytes = try Data(contentsOf: firstURL)
        XCTAssertEqual(firstOutput.sha256, FloeDigest.sha256Hex(firstBytes))
        XCTAssertEqual(firstOutput.byteCount, firstBytes.count)
        XCTAssertEqual(firstBytes.prefix(4), Data([0, 1, 0, 0]))
        let descriptors = try XCTUnwrap(CTFontManagerCreateFontDescriptorsFromData(firstBytes as CFData) as? [CTFontDescriptor])
        let descriptor = try XCTUnwrap(descriptors.first)
        let font = CTFontCreateWithFontDescriptor(descriptor, 1000, nil)
        var scalar: UniChar = 65, glyph: CGGlyph = 0, advance = CGSize.zero
        XCTAssertTrue(CTFontGetGlyphsForCharacters(font, &scalar, &glyph, 1))
        XCTAssertEqual(CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1), 725, accuracy: 1)
        let beforeImport = try await library.project(project.id)
        XCTAssertEqual(beforeImport.revision, 2)

        // The first real run has persisted its completion-critical manifest.
        // Import its canonical ID directly: no attachment conversion, path,
        // manual event/receipt, extra tool, or test-only source resolver.
        let canonicalID = "output:\(firstRun.uuidString):\(firstOutput.outputID)"
        let secondRun = UUID(), originalCall = "font-contract-original-" + UUID().uuidString
        let secondCalls = try [
            call("font-contract-reimport", "font.import", .object(["projectID": projectID, "baseRevision": .number(2), "fileID": .string(canonicalID)])),
            call("font-contract-read", "font.query", .object(["projectID": projectID, "baseRevision": .number(3), "command": .string("font.glyph"),
                "arguments": .object(["glyph": .string("A"), "offset": .number(0), "limit": .number(1)])])),
            call(originalCall, "font.export", .object(["projectID": projectID, "baseRevision": .number(3), "command": .string("file.export"),
                "arguments": .object(["format": .string("original")])]))
        ]
        try await runScript(environment: environment, task: task, run: secondRun, stores: stores, calls: secondCalls)
        let reexport = try await output(environment: environment, task: task, run: secondRun, callID: originalCall)
        let originalURL = try verifiedURL(reexport)
        XCTAssertEqual(try Data(contentsOf: originalURL), firstBytes)
        XCTAssertEqual(try Data(contentsOf: firstURL), firstBytes)
        XCTAssertEqual(reexport.sha256, firstOutput.sha256)
        let afterImport = try await library.project(project.id)
        XCTAssertEqual(afterImport.revision, 3)
        let directory = try await library.directory(for: project.id)
        let store = try HeavyEditorProjectStore(directory: directory, documentID: project.id, kind: .font)
        let document = try await store.read(), data = document.content.fontDesignData
        let importedA = try XCTUnwrap(data["glyphs"].array.first { $0["unicodes"].array.contains(.number(65)) })
        XCTAssertEqual(importedA["advance"].number, 725)
        let originalBase64 = try XCTUnwrap(data["original"]["base64"].string)
        XCTAssertEqual(Data(base64Encoded: originalBase64), firstBytes)
        let foreignRows = try await SQLiteRunOutputReader(database: environment.database)
            .manifestRows(runID: firstRun, expectedConversationID: UUID())
        XCTAssertTrue(foreignRows.isEmpty)
        // Keep only these uniquely owned originals/runs for Main's App readback.
        // No installed font, user project, user run or global policy is changed.
        print("FLOE_FONT_APP_CONTRACT|project=\(project.id)|task=\(task)|exportRun=\(firstRun)|importRun=\(secondRun)|sha256=\(firstOutput.sha256)")
    }
}
#endif
