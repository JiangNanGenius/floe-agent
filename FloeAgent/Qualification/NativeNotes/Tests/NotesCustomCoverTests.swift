// SPDX-License-Identifier: MPL-2.0
//
// NativeNotes host tests — `notes.cover` assistant tool + cover service
// priority (job-3d1d4048e9a34730, lane N).
//
// These run in the FloeNotesNativeQualification host with a real Notes store:
// tool registration and schema, read/set/restore with content+cover revision
// baselines, stale cover revision refusal, revoked-grant refusal at execute
// time, invalid raster refusal, freshly imported asset cleanup on refusal, the
// approval-policy semantics (owned document edit inherits the grant) and the
// custom-cover priority through the real cover service.
import XCTest
import Foundation
import UIKit
import FloeNotes
import FloeModels
import FloeSecurity
import FloeTools
// The same checks run in both hosts: the NativeNotes qualification project
// compiles this file against its own app module, while the App test bundle
// compiles it against FloeApp (the Notes cover wiring lives in the App
// target), so no second full qualification build is needed.
#if canImport(FloeNotesNativeQualification)
@testable import FloeNotesNativeQualification
#else
@testable import FloeApp
#endif

/// Main-actor isolated: the App host compiles with NonisolatedNonsendingByDefault,
/// and these tests call main-actor store/repository seams.
@MainActor
final class NotesCustomCoverTests: XCTestCase {
    private struct Harness {
        let store: NotesStore
        let root: URL
        let conversation: UUID
    }

    private static let tinyPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    /// A real 2x2 PNG whose pixel bytes differ per seed, so content
    /// addressing yields a NEW resource for each requested asset (two imports
    /// of the same bytes always dedupe to one id).
    private static func distinctPNG(_ seed: UInt8) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let image = renderer.image { context in
            context.cgContext.setFillColor(UIColor(red: CGFloat(seed) / 255.0,
                                                   green: 0.25,
                                                   blue: 0.75,
                                                   alpha: 1).cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        return try XCTUnwrap(image.pngData())
    }

    /// Writes one distinct cover image into an authorized workspace and
    /// returns the tool-relative path.
    private func workspaceCover(_ directory: URL, name: String, seed: UInt8) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.distinctPNG(seed).write(to: directory.appendingPathComponent(name))
        return name
    }

    private func makeHarness() async throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-cover-host-\(UUID().uuidString)", isDirectory: true)
        let store = try NotesStore(root: root)
        let conversation = UUID()
        await NotesRepository.shared.setStoreOverride(store)
        return Harness(store: store, root: root, conversation: conversation)
    }

    private func makeDocument(_ harness: Harness, title: String = "封面验收文档") async throws -> NoteDocument {
        var document = NoteDocument(kind: .notebook, title: title)
        document.pages[0].elements = [NoteElement(frame: NoteRect(x: 40, y: 40, width: 400, height: 120),
                                                  text: "正文内容", fontSize: 24)]
        let created = try await harness.store.create(document)
        try await harness.store.bindAssistant(conversationID: harness.conversation,
                                              documentID: created.id, canEdit: true)
        return created
    }

    private func importNormalizedCover(_ harness: Harness) async throws -> UUID {
        try await NotesCoverImageProcessor.importCover(data: Self.tinyPNG, store: harness.store)
    }

    private func importDistinctCover(_ harness: Harness, seed: UInt8) async throws -> UUID {
        try await NotesCoverImageProcessor.importCover(data: Self.distinctPNG(seed), store: harness.store)
    }

    private func context(for harness: Harness, workspace: URL? = nil) -> ToolContext {
        ToolContext(runID: UUID(), toolCallID: "cover-call", scope: .local,
                    workspaceRootURL: workspace, cancellation: CancellationToken(),
                    conversationID: harness.conversation)
    }

    private func runTool(_ json: String, context: ToolContext) async throws -> (output: ToolExecutionOutput, result: [String: Any]) {
        let args = try JSONDecoder().decode(NotesCoverTool.Arguments.self, from: Data(json.utf8))
        try NotesCoverTool().validate(args)
        let output = try await NotesCoverTool().execute(args, context: context)
        guard let object = try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any] else {
            XCTFail("tool result is not a JSON object: \(output.summary)")
            return (output, [:])
        }
        return (output, object)
    }

    private func liveCover(_ harness: Harness, _ documentID: UUID) async throws -> UUID? {
        try await harness.store.document(documentID).coverResourceID
    }

    private func resourceCount(_ harness: Harness) throws -> Int {
        let directory = harness.root.appendingPathComponent("Resources", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { !$0.lastPathComponent.hasPrefix(".import-") }.count
    }

    // MARK: registration and schema

    func testToolIsRegisteredAndOfferedToTheNotesAssistant() throws {
        NotesToolRegistration.register()
        XCTAssertNotNil(ToolCatalog.descriptor(named: NotesCoverTool.name), "notes.cover must be in the tool catalog")
        XCTAssertTrue(ToolRunnerRegistry.shared.runner(named: NotesCoverTool.name) != nil)
        XCTAssertTrue(NotesAssistantToolCatalog.toolNames.contains(NotesCoverTool.name))
        XCTAssertTrue(NotesAssistantToolCatalog.scopedAutoGrantToolNames.contains(NotesCoverTool.name))
        let capability = NoteCapabilityMatrix.capabilities.first { $0.tool == NotesCoverTool.name }
        XCTAssertEqual(capability?.tier, .implemented)
        XCTAssertEqual(Set(capability?.actions ?? []), ["read", "set", "restore"])
    }

    // MARK: read / set / restore

    func testReadReportsNormalizedCoverRevisionAndAuthorizedImages() async throws {
        let harness = try await makeHarness()
        addTeardownBlock {
            await NotesRepository.shared.setStoreOverride(nil)
            try? FileManager.default.removeItem(at: harness.root)
        }
        let document = try await makeDocument(harness)
        _ = try await importNormalizedCover(harness)

        let (output, result) = try await runTool(#"{"documentID":"\#(document.id.uuidString)"}"#,
                                                context: context(for: harness))
        XCTAssertEqual(output.exitStatus, 0)
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["status"] as? String, "read")
        XCTAssertEqual(result["revision"] as? Int, document.revision)
        let cover = try XCTUnwrap(result["cover"] as? [String: Any])
        XCTAssertEqual(cover["mode"] as? String, "automatic")
        XCTAssertEqual(cover["coverRevision"] as? Int, 0, "a never-customized cover reads as normalized 0")
        XCTAssertNil(cover["resourceID"] as? String)
    }

    func testSetAndRestoreReadBackTheActualCoverRevision() async throws {
        let harness = try await makeHarness()
        addTeardownBlock {
            await NotesRepository.shared.setStoreOverride(nil)
            try? FileManager.default.removeItem(at: harness.root)
        }
        let document = try await makeDocument(harness)
        // The authorized-asset contract: `resourceID` must name an image that
        // a document selected for this task already references; a NEW image
        // travels through the task-authorized workspace `path`. Both end in
        // the same deterministic command.
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("cover-workspace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        _ = try workspaceCover(workspace, name: "first.png", seed: 11)
        let baseContext = context(for: harness, workspace: workspace)

        let (setOutput, setResult) = try await runTool(
            #"{"documentID":"\#(document.id.uuidString)","action":"set","expectedRevision":\#(document.revision),"expectedCoverRevision":0,"path":"first.png"}"#,
            context: baseContext)
        XCTAssertEqual(setOutput.exitStatus, 0)
        XCTAssertEqual(setResult["status"] as? String, "updated")
        var cover = try XCTUnwrap(setResult["cover"] as? [String: Any])
        XCTAssertEqual(cover["mode"] as? String, "custom")
        let asset = try XCTUnwrap(cover["resourceID"] as? String)
        XCTAssertEqual(cover["coverRevision"] as? Int, 1)
        XCTAssertEqual(setResult["revision"] as? Int, document.revision, "the content revision is untouched")

        // Repeated set of the settled state is an idempotent no-op.
        let (repeatOutput, repeatResult) = try await runTool(
            #"{"documentID":"\#(document.id.uuidString)","action":"set","expectedRevision":\#(document.revision),"expectedCoverRevision":0,"path":"first.png"}"#,
            context: baseContext)
        XCTAssertEqual(repeatOutput.exitStatus, 0)
        XCTAssertEqual(repeatResult["status"] as? String, "unchanged")

        let (restoreOutput, restoreResult) = try await runTool(
            #"{"documentID":"\#(document.id.uuidString)","action":"restore","expectedRevision":\#(document.revision),"expectedCoverRevision":1}"#,
            context: baseContext)
        XCTAssertEqual(restoreOutput.exitStatus, 0)
        XCTAssertEqual(restoreResult["status"] as? String, "updated")
        cover = try XCTUnwrap(restoreResult["cover"] as? [String: Any])
        XCTAssertEqual(cover["mode"] as? String, "automatic")
        XCTAssertEqual(cover["coverRevision"] as? Int, 2)
    }

    // MARK: races

    func testStaleCoverRevisionIsRefusedWithoutOverwritingTheManualCover() async throws {
        let harness = try await makeHarness()
        addTeardownBlock {
            await NotesRepository.shared.setStoreOverride(nil)
            try? FileManager.default.removeItem(at: harness.root)
        }
        let document = try await makeDocument(harness)
        let first = try await importDistinctCover(harness, seed: 21)
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("cover-workspace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        _ = try workspaceCover(workspace, name: "second.png", seed: 22)
        let baseContext = context(for: harness, workspace: workspace)

        // The manual UI (native path) sets the first cover at coverRevision 0.
        let manual = try await NotesCoverCommandService.apply(.useResource(first), documentID: document.id,
                                                              expectedRevision: document.revision,
                                                              expectedCoverRevision: 0, store: harness.store)
        XCTAssertEqual(manual.coverRevision, 1)

        // The assistant still holds the baseline it read (0) and must fail closed.
        let (output, result) = try await runTool(
            #"{"documentID":"\#(document.id.uuidString)","action":"set","expectedRevision":\#(document.revision),"expectedCoverRevision":0,"path":"second.png"}"#,
            context: baseContext)
        XCTAssertEqual(output.exitStatus, 1)
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["status"] as? String, "staleCoverRevision")
        let cover = try XCTUnwrap(result["cover"] as? [String: Any])
        XCTAssertEqual(cover["resourceID"] as? String, first.uuidString, "the refused write must not overwrite the cover")
        XCTAssertEqual(cover["coverRevision"] as? Int, 1)
        let live = try await harness.store.document(document.id)
        XCTAssertEqual(live.coverResourceID, first)
    }

    func testRestoreRaceIsRefusedAndSucceedsAfterReread() async throws {
        let harness = try await makeHarness()
        addTeardownBlock {
            await NotesRepository.shared.setStoreOverride(nil)
            try? FileManager.default.removeItem(at: harness.root)
        }
        let document = try await makeDocument(harness)
        let asset = try await importDistinctCover(harness, seed: 31)
        let baseContext = context(for: harness)
        _ = try await NotesCoverCommandService.apply(.useResource(asset), documentID: document.id,
                                                     expectedRevision: document.revision,
                                                     expectedCoverRevision: 0, store: harness.store)
        // Another session replaces the cover (distinct bytes, so this really
        // is a new cover revision); the pending restore is stale.
        let replacement = try await importDistinctCover(harness, seed: 32)
        _ = try await NotesCoverCommandService.apply(.useResource(replacement), documentID: document.id,
                                                     expectedRevision: document.revision,
                                                     expectedCoverRevision: 1, store: harness.store)

        let (output, result) = try await runTool(
            #"{"documentID":"\#(document.id.uuidString)","action":"restore","expectedRevision":\#(document.revision),"expectedCoverRevision":1}"#,
            context: baseContext)
        XCTAssertEqual(output.exitStatus, 1)
        XCTAssertEqual(result["status"] as? String, "staleCoverRevision")
        let replacedCover = try await liveCover(harness, document.id)
        XCTAssertEqual(replacedCover, replacement)

        // Re-reading the current cover revision succeeds.
        let (retryOutput, retryResult) = try await runTool(
            #"{"documentID":"\#(document.id.uuidString)","action":"restore","expectedRevision":\#(document.revision),"expectedCoverRevision":2}"#,
            context: baseContext)
        XCTAssertEqual(retryOutput.exitStatus, 0)
        let restoredCover = try await liveCover(harness, document.id)
        XCTAssertEqual(restoredCover, nil)
        let cover = try XCTUnwrap(retryResult["cover"] as? [String: Any])
        XCTAssertEqual(cover["coverRevision"] as? Int, 3)
    }

    func testRevokedGrantIsRefusedAtExecuteTime() async throws {
        let harness = try await makeHarness()
        addTeardownBlock {
            await NotesRepository.shared.setStoreOverride(nil)
            try? FileManager.default.removeItem(at: harness.root)
        }
        let document = try await makeDocument(harness)
        let asset = try await importNormalizedCover(harness)
        let baseContext = context(for: harness)

        try await harness.store.revokeAccess(conversationID: harness.conversation, documentID: document.id)
        let (output, result) = try await runTool(
            #"{"documentID":"\#(document.id.uuidString)","action":"set","expectedRevision":\#(document.revision),"expectedCoverRevision":0,"resourceID":"\#(asset.uuidString)"}"#,
            context: baseContext)
        XCTAssertEqual(output.exitStatus, 1)
        XCTAssertEqual(result["status"] as? String, "editingNotAuthorized")
        let deniedCover = try await liveCover(harness, document.id)
        XCTAssertEqual(deniedCover, nil)
    }

    // MARK: invalid assets and cleanup

    func testInvalidRasterIsRefusedAndPreviousCoverIsPreserved() async throws {
        let harness = try await makeHarness()
        addTeardownBlock {
            await NotesRepository.shared.setStoreOverride(nil)
            try? FileManager.default.removeItem(at: harness.root)
        }
        let document = try await makeDocument(harness)
        let good = try await importDistinctCover(harness, seed: 41)
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("cover-workspace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"/>".utf8)
            .write(to: workspace.appendingPathComponent("vector.svg"))
        try Data("not an image".utf8).write(to: workspace.appendingPathComponent("corrupt.png"))
        let baseContext = context(for: harness, workspace: workspace)
        _ = try await NotesCoverCommandService.apply(.useResource(good), documentID: document.id,
                                                     expectedRevision: document.revision,
                                                     expectedCoverRevision: 0, store: harness.store)

        // A vector file is refused by the shared bounded raster validation.
        let (output, result) = try await runTool(
            #"{"documentID":"\#(document.id.uuidString)","action":"set","expectedRevision":\#(document.revision),"expectedCoverRevision":1,"path":"vector.svg"}"#,
            context: baseContext)
        XCTAssertEqual(output.exitStatus, 1)
        XCTAssertEqual(result["status"] as? String, "notAnImage")
        let preservedCover = try await liveCover(harness, document.id)
        XCTAssertEqual(preservedCover, good)

        // A corrupt "image/png" file is refused by the real raster validation too.
        let (corruptOutput, corruptResult) = try await runTool(
            #"{"documentID":"\#(document.id.uuidString)","action":"set","expectedRevision":\#(document.revision),"expectedCoverRevision":1,"path":"corrupt.png"}"#,
            context: baseContext)
        XCTAssertEqual(corruptOutput.exitStatus, 1)
        XCTAssertEqual(corruptResult["status"] as? String, "notAnImage")
        let preservedAfterCorrupt = try await liveCover(harness, document.id)
        XCTAssertEqual(preservedAfterCorrupt, good)
    }

    func testPathImportThatLosesTheRaceLeavesNoUnreferencedAsset() async throws {
        let harness = try await makeHarness()
        addTeardownBlock {
            await NotesRepository.shared.setStoreOverride(nil)
            try? FileManager.default.removeItem(at: harness.root)
        }
        let document = try await makeDocument(harness)
        // A task-authorized workspace with a real cover image.
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("cover-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try Self.distinctPNG(52).write(to: workspace.appendingPathComponent("cover.png"))
        let before = try resourceCount(harness)

        // The assistant reads coverRevision 0, then the manual UI sets a cover,
        // so the assistant's set with the stale baseline must fail closed and
        // remove the asset it had just imported.
        let first = try await importDistinctCover(harness, seed: 51)
        _ = try await NotesCoverCommandService.apply(.useResource(first), documentID: document.id,
                                                     expectedRevision: document.revision,
                                                     expectedCoverRevision: 0, store: harness.store)

        let (output, result) = try await runTool(
            #"{"documentID":"\#(document.id.uuidString)","action":"set","expectedRevision":\#(document.revision),"expectedCoverRevision":0,"path":"cover.png"}"#,
            context: context(for: harness, workspace: workspace))
        XCTAssertEqual(output.exitStatus, 1)
        XCTAssertEqual(result["status"] as? String, "staleCoverRevision")
        let preserved = try await liveCover(harness, document.id)
        XCTAssertEqual(preserved, first)
        XCTAssertEqual(try resourceCount(harness), before + 1,
                       "only the manual cover asset may remain; the refused import must be discarded")
    }

    // MARK: approval policy

    func testCoverApprovalFollowsDocumentEditOwnership() async throws {
        let harness = try await makeHarness()
        addTeardownBlock {
            await NotesRepository.shared.setStoreOverride(nil)
            try? FileManager.default.removeItem(at: harness.root)
        }
        let document = try await makeDocument(harness)
        let stranger = try await harness.store.create(NoteDocument(kind: .notebook, title: "未授权"))
        let policy = NotesDocumentApprovalPolicy(conversationID: harness.conversation, store: harness.store)

        func decide(_ toolName: String, _ json: String) async throws -> ApprovalDecision {
            try await policy.decide(ProposedAction(
                toolCall: try ToolCall(id: "call-1", toolName: toolName,
                                       argumentsJSON: Data(json.utf8), scope: .local),
                riskLabels: [], userGoal: "修改封面", hostAndPathScope: .local))
        }

        let read = try await decide(NotesCoverTool.name, #"{"documentID":"\#(document.id.uuidString)"}"#)
        guard case .allow = read else { return XCTFail("cover read should inherit the document selection: \(read)") }

        let set = try await decide(NotesCoverTool.name,
                                   #"{"documentID":"\#(document.id.uuidString)","action":"set","expectedRevision":1,"expectedCoverRevision":0,"resourceID":"x"}"#)
        guard case .allow = set else { return XCTFail("owned document cover edit should inherit the grant: \(set)") }

        let strangerDecision = try await decide(NotesCoverTool.name,
                                                #"{"documentID":"\#(stranger.id.uuidString)","action":"set","expectedRevision":1,"expectedCoverRevision":0,"resourceID":"x"}"#)
        guard case .deny = strangerDecision else {
            return XCTFail("a document outside the assistant session must be denied: \(strangerDecision)")
        }
    }

    // MARK: cover service priority

    @MainActor
    func testCustomCoverOutranksAutomaticRendererAndRestoreReachesIt() async throws {
        let harness = try await makeHarness()
        addTeardownBlock {
            await NotesRepository.shared.setStoreOverride(nil)
            try? FileManager.default.removeItem(at: harness.root)
        }
        var document = try await makeDocument(harness)
        let asset = try await importNormalizedCover(harness)
        document = try await NotesCoverCommandService.apply(.useResource(asset), documentID: document.id,
                                                            expectedRevision: document.revision,
                                                            expectedCoverRevision: 0, store: harness.store)

        let size = CGSize(width: 320, height: 420)
        let custom = await NotesDocumentCoverService.render(document: document, store: harness.store,
                                                            size: size, maximumSourceBytes: 128 * 1024 * 1024)
        XCTAssertEqual(custom.source, .customCover)
        XCTAssertNotNil(custom.image)

        let restored = try await NotesCoverCommandService.apply(.restoreAutomatic, documentID: document.id,
                                                                expectedRevision: document.revision,
                                                                expectedCoverRevision: 1, store: harness.store)
        let automatic = await NotesDocumentCoverService.render(document: restored, store: harness.store,
                                                               size: size, maximumSourceBytes: 128 * 1024 * 1024)
        XCTAssertEqual(automatic.source, .notePage, "restore must reach the original automatic renderer")
        XCTAssertNotNil(automatic.image)
    }
}
