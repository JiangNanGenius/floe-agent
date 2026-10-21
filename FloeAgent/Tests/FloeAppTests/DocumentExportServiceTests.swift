// Focused App tests for the shared assistant document export service.
//
// Real pieces used here: `NotesStore` on a temporary root, the production
// notebook PDF / mind-map Markdown renderers, `NotesArchive`, the production
// `RunOutputSnapshotStore` publisher/verifier under a private artifact root,
// and the real never-overwrite commit. The Office engine itself is NOT run in
// this unit test; the assistant integration/engine acceptance stays with the
// primary App build and native qualification.
//
// Covered: a read grant is required, `expectedRevision` fails closed, a
// different existing destination is never overwritten while identical bytes
// are an idempotent success, the published receipt verifies its actual binary
// snapshot, unsupported format/option combinations refuse, and cancellation
// produces no file.

import Testing
import Foundation
import FloeCore
import FloeDocuments
import FloeModels
import FloeNotes
import FloeTools
@testable import FloeApp

@Suite("Assistant document export service")
@MainActor
struct DocumentExportServiceTests {
    private let conversationID = UUID()
    private let runID = UUID()

    private struct Harness {
        let root: URL
        let workspace: URL
        let artifactRoot: URL
        let store: NotesStore

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeHarness() throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentExportServiceTests-\(UUID().uuidString)", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let artifactRoot = root.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: true)
        let store = try NotesStore(root: root.appendingPathComponent("notes", isDirectory: true))
        return Harness(root: root, workspace: workspace, artifactRoot: artifactRoot, store: store)
    }

    // MARK: - Receipt and no-overwrite

    @Test func markdownExportPublishesVerifiedBinarySnapshotAndIsIdempotent() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let created = try await makeMindMap(title: "Release Plan", store: harness.store)
        try await harness.store.grantAccess(
            conversationID: conversationID, documentID: created.id, canEdit: false)
        let callID = "call-markdown"
        let context = makeContext(workspace: harness.workspace, callID: callID)

        let request = DocumentExportRequest(
            documentID: created.id,
            format: .markdown,
            scope: DocumentExportScope(),
            expectedRevision: created.revision,
            targetPath: "exports/plan.md")
        let first = try await DocumentExportService.export(
            request, store: harness.store, context: context, artifactRoot: harness.artifactRoot)
        #expect(first.status == "exported")
        #expect(first.format == "markdown")
        #expect(first.displayName == "plan.md")
        #expect(first.mimeType == "text/markdown")
        #expect(first.relativePath == "exports/plan.md")
        #expect(!first.sha256.isEmpty)

        let destination = harness.workspace.appendingPathComponent("exports/plan.md")
        let committed = try Data(contentsOf: destination)
        #expect(committed.count == first.byteCount)
        #expect(FloeDigest.sha256Hex(committed) == first.sha256)

        let receipt = try #require(first.outputFile)
        #expect(receipt.runID == runID)
        #expect(receipt.taskID == conversationID)
        #expect(receipt.producerCallID == callID)
        #expect(receipt.producerTool == "notes.export")
        #expect(receipt.slot == "export")
        #expect(receipt.isCanonicalForCurrentRun)
        #expect(receipt.hasRuntimeConsistentIdentity)
        guard case .verified(let snapshotURL) = RunOutputSnapshotStore.verify(
            receipt, artifactRoot: harness.artifactRoot) else {
            Issue.record("the published receipt must resolve the exact committed bytes")
            return
        }
        #expect(try Data(contentsOf: snapshotURL) == committed)

        // Identical replay: no rewrite, honest alreadyExported status, same
        // receipt identity (same run/call/slot).
        let second = try await DocumentExportService.export(
            request, store: harness.store, context: context, artifactRoot: harness.artifactRoot)
        #expect(second.status == "alreadyExported")
        #expect(second.sha256 == first.sha256)
        #expect(second.outputFile?.outputID == receipt.outputID)
        #expect(try Data(contentsOf: destination) == committed)
    }

    @Test func differentExistingDestinationIsNeverOverwritten() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let created = try await makeMindMap(title: "Do Not Clobber", store: harness.store)
        try await harness.store.grantAccess(
            conversationID: conversationID, documentID: created.id, canEdit: false)
        let destinationFolder = harness.workspace.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        let destination = destinationFolder.appendingPathComponent("keep.md")
        let original = Data("existing user bytes".utf8)
        try original.write(to: destination)

        let request = DocumentExportRequest(
            documentID: created.id,
            format: .markdown,
            scope: DocumentExportScope(),
            expectedRevision: created.revision,
            targetPath: "exports/keep.md")
        do {
            _ = try await DocumentExportService.export(
                request, store: harness.store,
                context: makeContext(workspace: harness.workspace),
                artifactRoot: harness.artifactRoot)
            Issue.record("a different existing destination must fail instead of being replaced")
        } catch {
            #expect(try Data(contentsOf: destination) == original)
        }
    }

    // MARK: - Grant, revision, cancellation

    @Test func exportRequiresReadGrantAndFailsClosedOnRevision() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let created = try await makeMindMap(title: "Granted Later", store: harness.store)
        let request = DocumentExportRequest(
            documentID: created.id,
            format: .markdown,
            scope: DocumentExportScope(),
            expectedRevision: created.revision,
            targetPath: "exports/granted.md")
        do {
            _ = try await DocumentExportService.export(
                request, store: harness.store,
                context: makeContext(workspace: harness.workspace),
                artifactRoot: harness.artifactRoot)
            Issue.record("an ungranted document must not export")
        } catch {}
        #expect(!FileManager.default.fileExists(
            atPath: harness.workspace.appendingPathComponent("exports/granted.md").path))

        try await harness.store.grantAccess(
            conversationID: conversationID, documentID: created.id, canEdit: false)
        var stale = request
        stale.expectedRevision = created.revision + 1
        do {
            _ = try await DocumentExportService.export(
                stale, store: harness.store,
                context: makeContext(workspace: harness.workspace),
                artifactRoot: harness.artifactRoot)
            Issue.record("a stale expectedRevision must fail closed")
        } catch {}
        #expect(!FileManager.default.fileExists(
            atPath: harness.workspace.appendingPathComponent("exports/granted.md").path))
    }

    @Test func cancellationProducesNoFile() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let created = try await makeMindMap(title: "Cancel Me", store: harness.store)
        try await harness.store.grantAccess(
            conversationID: conversationID, documentID: created.id, canEdit: false)
        let token = CancellationToken()
        token.cancel()
        let request = DocumentExportRequest(
            documentID: created.id,
            format: .markdown,
            scope: DocumentExportScope(),
            expectedRevision: created.revision,
            targetPath: "exports/cancelled.md")
        do {
            _ = try await DocumentExportService.export(
                request, store: harness.store,
                context: makeContext(workspace: harness.workspace, cancellation: token),
                artifactRoot: harness.artifactRoot)
            Issue.record("a cancelled export must not succeed")
        } catch {}
        #expect(!FileManager.default.fileExists(
            atPath: harness.workspace.appendingPathComponent("exports/cancelled.md").path))
    }

    // MARK: - Real notebook renderer and truthful capabilities

    @Test func notebookPDFPageSelectionProducesMeasuredFile() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        var notebook = NoteDocument(title: "Notebook Export")
        notebook.pages[0].elements = [
            NoteElement(frame: .init(x: 40, y: 40, width: 400, height: 100), text: "第一页")
        ]
        try NoteEdit.insertPage(NotePage(), at: 1).apply(to: &notebook)
        let created = try await harness.store.create(notebook)
        try await harness.store.grantAccess(
            conversationID: conversationID, documentID: created.id, canEdit: false)

        let request = DocumentExportRequest(
            documentID: created.id,
            format: .pdf,
            scope: DocumentExportScope(pages: "2"),
            expectedRevision: created.revision,
            targetPath: "exports/notebook.pdf")
        let result = try await DocumentExportService.export(
            request, store: harness.store,
            context: makeContext(workspace: harness.workspace, callID: "call-pdf"),
            artifactRoot: harness.artifactRoot)
        #expect(result.pageCount == 1)
        #expect(result.selectedPages == [2])
        #expect(result.mimeType == "application/pdf")
        #expect(result.uti == "com.adobe.pdf")
        let data = try Data(contentsOf: result.fileURL)
        #expect(String(decoding: data.prefix(5), as: UTF8.self) == "%PDF-")
        #expect(data.count == result.byteCount)
        let receipt = try #require(result.outputFile)
        guard case .verified(_) = RunOutputSnapshotStore.verify(
            receipt, artifactRoot: harness.artifactRoot) else {
            Issue.record("the notebook PDF receipt must verify")
            return
        }
    }

    @Test func capabilitiesComeFromTheSameServiceAndStateRealSupport() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let notebook = try await harness.store.create(NoteDocument(title: "Notebook Capabilities"))
        try await harness.store.grantAccess(
            conversationID: conversationID, documentID: notebook.id, canEdit: true)
        let notebookCaps = try await DocumentExportService.capabilities(
            documentID: notebook.id, includeLayout: true, store: harness.store)
        #expect(notebookCaps.kind == "notebook")
        #expect(notebookCaps.pdf?.pageCount == 1)
        #expect(notebookCaps.pdf?.pageIDsSupported == true)
        #expect(notebookCaps.pdf?.sheetScopeSupported == false)
        #expect(notebookCaps.formats.first(where: { $0.format == "pdf" })?.supported == true)
        #expect(notebookCaps.formats.first(where: { $0.format == "markdown" })?.supported == false)

        let mindMap = try await makeMindMap(title: "Mind Map Capabilities", store: harness.store)
        try await harness.store.grantAccess(
            conversationID: conversationID, documentID: mindMap.id, canEdit: false)
        let mapCaps = try await DocumentExportService.capabilities(
            documentID: mindMap.id, includeLayout: false, store: harness.store)
        #expect(mapCaps.kind == "mindMap")
        #expect(mapCaps.pdf?.engine == nil)
        #expect(mapCaps.formats.first(where: { $0.format == "markdown" })?.supported == true)
        #expect(mapCaps.formats.first(where: { $0.format == "original" })?.supported == false)
    }

    @Test func unsupportedFormatAndScopeCombinationsRefuse() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let mindMap = try await makeMindMap(title: "No PDF", store: harness.store)
        try await harness.store.grantAccess(
            conversationID: conversationID, documentID: mindMap.id, canEdit: false)
        do {
            _ = try await DocumentExportService.export(
                DocumentExportRequest(documentID: mindMap.id, format: .pdf,
                                      scope: DocumentExportScope(),
                                      expectedRevision: mindMap.revision,
                                      targetPath: "exports/map.pdf"),
                store: harness.store,
                context: makeContext(workspace: harness.workspace),
                artifactRoot: harness.artifactRoot)
            Issue.record("a mind map has no PDF renderer")
        } catch {}

        // Tool-level structural gate: pages/pageIDs are PDF-only.
        let floenoteWithPages = try JSONDecoder().decode(
            NotesExportTool.Arguments.self,
            from: Data(#"{"documentID":"\#(mindMap.id.uuidString)","format":"floenote","pages":"1"}"#.utf8))
        #expect(throws: (any Error).self) { try NotesExportTool().validate(floenoteWithPages) }

        let rangeWithoutSheet = try JSONDecoder().decode(
            NotesExportTool.Arguments.self,
            from: Data(#"{"documentID":"\#(mindMap.id.uuidString)","format":"pdf","cellRange":"A1:B2"}"#.utf8))
        #expect(throws: (any Error).self) { try NotesExportTool().validate(rangeWithoutSheet) }
    }

    @Test func documentConversionValidatesOfficePDFAndPages() throws {
        for ext in ["docx", "xlsx", "pptx"] {
            try DocumentFileConverter.validate(
                DocumentConversionArguments(inputPath: "inputs/book.\(ext)", outputPath: "out/book.pdf",
                                            format: "pdf", pages: "1-2"),
                requiresPDF: true)
        }
        #expect(throws: (any Error).self) {
            try DocumentFileConverter.validate(
                DocumentConversionArguments(inputPath: "inputs/book.pdf", outputPath: "out/book.xlsx",
                                            format: "xlsx", pages: nil),
                requiresPDF: true)
        }
        #expect(throws: (any Error).self) {
            try DocumentFileConverter.validate(
                DocumentConversionArguments(inputPath: "inputs/book.xlsx", outputPath: "out/book.html",
                                            format: "html", pages: nil),
                requiresPDF: false)
        }
        #expect(throws: (any Error).self) {
            try DocumentFileConverter.validate(
                DocumentConversionArguments(inputPath: "inputs/note.md", outputPath: "out/note.pdf",
                                            format: "pdf", pages: "2"),
                requiresPDF: true)
        }
    }

    // MARK: - Opt-in actual Office producer (parent native host)

    /// Real pinned-engine `notes.export` on the same private runtime workbook
    /// the PDF backend lane qualifies (`FLOE_OFFICE_EXPORT_QUALIFICATION=1`,
    /// `FLOE_OFFICE_PRIVATE_WORKBOOK_BASE64`, `FLOE_OFFICE_PRIVATE_WORKBOOK_SHA256`).
    /// Runs only on the canonical serialized iPad host; on every other host it
    /// returns without touching the engine. No PDF bytes or engine call are
    /// mocked: the document is a real `NotesStore` office document, the export
    /// goes through the shared `OfficePDFExportService`, and the delivered file
    /// is re-verified against its sealed `RunOutputSnapshotStore` receipt.
    #if canImport(UIKit) && canImport(FloeOfficeNative) && targetEnvironment(simulator) && DEBUG
    @Test func optInActualOfficeNotesExportProducesVerifiedOnePageSnapshot() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FLOE_OFFICE_EXPORT_QUALIFICATION"] == "1",
              let encoded = environment["FLOE_OFFICE_PRIVATE_WORKBOOK_BASE64"],
              let expected = environment["FLOE_OFFICE_PRIVATE_WORKBOOK_SHA256"] else {
            // Opt-in only: ordinary hosts (and every non-qualification CI leg)
            // run the synthetic tests above and never boot the engine here.
            return
        }
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let data = try #require(Data(base64Encoded: encoded))
        #expect(data.count < 512 * 1024)
        let source = harness.root.appendingPathComponent("provided.xlsx")
        try data.write(to: source, options: .atomic)
        #expect(try FloeDigest.sha256Hex(ofFileAt: source) == expected)

        // A real Notes office document backed by the provided package bytes.
        let resource = try await harness.store.importResource(
            from: source,
            mediaType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        var document = NoteDocument(kind: .office, title: "Provided Workbook")
        document.officeResourceID = resource
        document.officeFileName = "provided.xlsx"
        let created = try await harness.store.create(document)
        try await harness.store.grantAccess(
            conversationID: conversationID, documentID: created.id, canEdit: false)

        // Landscape + fit-to-one-page through the assistant producer: the
        // same route the UI Print/Export sheet uses, on the saved package.
        let callID = "call-office-notes-export"
        let context = makeContext(workspace: harness.workspace, callID: callID)
        let request = DocumentExportRequest(
            documentID: created.id,
            format: .pdf,
            scope: DocumentExportScope(paper: "a4", orientation: "landscape", fit: "fitToOnePage"),
            expectedRevision: created.revision,
            targetPath: "exports/provided.pdf")
        let result = try await DocumentExportService.export(
            request, store: harness.store, context: context, artifactRoot: harness.artifactRoot)

        #expect(result.status == "exported")
        #expect(result.mimeType == "application/pdf")
        #expect(result.uti == "com.adobe.pdf")
        #expect(result.pageCount == 1,
                "landscape fit-to-one-page must collapse the two portrait slices")
        #expect(result.sourceState == "savedResource")
        #expect(result.sourceSHA256 == expected.lowercased())
        let receipt = try #require(result.outputFile)
        #expect(receipt.producerTool == "notes.export")
        #expect(receipt.producerCallID == callID)
        #expect(receipt.runID == runID)
        #expect(receipt.displayName == "provided.pdf")
        guard case .verified(let snapshotURL) = RunOutputSnapshotStore.verify(
            receipt, artifactRoot: harness.artifactRoot) else {
            Issue.record("the actual Office export snapshot must verify against its receipt")
            return
        }
        let snapshot = try Data(contentsOf: snapshotURL)
        #expect(snapshot.count == result.byteCount)
        #expect(FloeDigest.sha256Hex(snapshot) == result.sha256)
        #expect(String(decoding: snapshot.prefix(5), as: UTF8.self) == "%PDF-")

        // Source untouched, no quarantine retained, workspace file equals snapshot.
        #expect(try FloeDigest.sha256Hex(ofFileAt: source) == expected)
        #expect(try Data(contentsOf: result.fileURL) == snapshot)
        let quarantined = await OfficeAutomaticExecutionGate.shared.isQuarantined
        #expect(!quarantined)
    }
    #endif

    // MARK: - Fixtures

    private func makeMindMap(title: String, store: NotesStore) async throws -> NoteDocument {
        try await store.create(NoteDocument(kind: .mindMap, title: title))
    }

    private func makeContext(workspace: URL,
                             callID: String = UUID().uuidString,
                             cancellation: CancellationToken = CancellationToken()) -> ToolContext {
        ToolContext(
            runID: runID,
            toolCallID: callID,
            scope: .local,
            workspaceRootURL: workspace,
            cancellation: cancellation,
            conversationID: conversationID)
    }
}
