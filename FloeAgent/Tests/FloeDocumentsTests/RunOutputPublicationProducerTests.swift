// FloeDocumentsTests — S3-D producer publication at the Office create and
// document.office.edit export boundaries. Production tools + the real core
// RunOutputSnapshotStore + a real filesystem; the shared fake Office host
// optionally commits real bytes so publication exercises the end-to-end path.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeTools
@testable import FloeDocuments

@Suite("FloeDocuments run-output publication (create tools)")
struct OfficeCreatePublicationProducerTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("s3d-office-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func removeSnapshotNamespace(for runID: UUID) {
        guard let base = try? FloeArtifactStore.root() else { return }
        try? FileManager.default.removeItem(at: base
            .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true))
    }

    private func boundContext(runID: UUID, conversation: UUID, root: URL) -> ToolContext {
        ToolContext(runID: runID,
                    toolCallID: "call-create-1",
                    scope: .local,
                    workspaceRootURL: root,
                    cancellation: CancellationToken(),
                    conversationID: conversation)
    }

    @Test("bound createWord publishes a verifying snapshot receipt")
    func createWordPublishes() async throws {
        let root = try temporaryRoot()
        let runID = UUID(), conversation = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { removeSnapshotNamespace(for: runID) }
        let tool = DocumentCreateWordTool(rootProvider: { root })
        let output = try await tool.execute(
            .init(path: "report.docx", title: "Report", paragraphs: ["Body"]),
            context: boundContext(runID: runID, conversation: conversation, root: root))
        #expect(output.exitStatus == 0)
        let published = try #require(output.outputFiles.first)
        #expect(output.outputFiles.count == 1)
        #expect(published.slot == "document")
        #expect(published.producerTool == "document.createWord")
        #expect(published.runID == runID)
        #expect(published.taskID == conversation)
        #expect(published.displayName == "report.docx")
        #expect(published.mimeType
                == "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        #expect(published.isCanonicalForCurrentRun)
        let copyURL = root.appendingPathComponent("report.docx")
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: copyURL)
        #expect(published.sha256 == sourceSHA)
        if case .verified = RunOutputSnapshotStore.verify(published) { }
        else { Issue.record("created document snapshot failed verification") }
    }

    @Test("editing the created original after publication never changes the snapshot")
    func snapshotSurvivesOriginalMutation() async throws {
        let root = try temporaryRoot()
        let runID = UUID(), conversation = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { removeSnapshotNamespace(for: runID) }
        let tool = DocumentCreateWorkbookTool(rootProvider: { root })
        let output = try await tool.execute(
            .init(path: "budget.xlsx", sheets: [.init(name: "Inputs", rows: [["a", "1"]])]),
            context: boundContext(runID: runID, conversation: conversation, root: root))
        let published = try #require(output.outputFiles.first)
        #expect(published.slot == "document")
        #expect(published.mimeType
                == "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        // Mutate the workspace original through a plain overwrite (as a later
        // tool or the user would).
        let original = root.appendingPathComponent("budget.xlsx")
        var mutated = try Data(contentsOf: original)
        mutated.append(Data("-edited-by-user".utf8))
        try mutated.write(to: original)
        if case .verified(let url) = RunOutputSnapshotStore.verify(published) {
            #expect(try Data(contentsOf: url) != mutated,
                    "snapshot must retain the bytes created at commit time")
            let snapshotSHA = try FloeDigest.sha256Hex(ofFileAt: url)
            #expect(published.sha256 == snapshotSHA)
        } else {
            Issue.record("snapshot must remain verified after the original changes")
        }
    }

    @Test("legacy direct create keeps the pre-publication summary exactly")
    func legacyDirectKeepsLegacySummary() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = DocumentCreateWordTool(rootProvider: { root })
        let output = try await tool.execute(
            .init(path: "legacy.docx", title: "Legacy", paragraphs: ["One"]),
            context: ToolContext(runID: UUID(), workspaceRootURL: root,
                                 cancellation: CancellationToken()))
        #expect(output.exitStatus == 0)
        #expect(output.summary == "created=legacy.docx format=docx paragraphs=2 fillableFields=0 "
            + "titleStyle=Title verified=true note=Plain document; no fillable form fields. "
            + "Use document.office.inspect/updateText for text edits.")
        #expect(output.outputFiles.isEmpty)
    }

    @Test("partially bound create fails observably and keeps the created original")
    func partiallyBoundCreateFails() async throws {
        let root = try temporaryRoot()
        let runID = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { removeSnapshotNamespace(for: runID) }
        let tool = DocumentCreateWorkbookTool(rootProvider: { root })
        // A tool-call binding without any task identity must not silently skip
        // the required publication.
        let context = ToolContext(runID: runID, toolCallID: "call-partial-1",
                                  workspaceRootURL: root, cancellation: CancellationToken())
        let output = try await tool.execute(
            .init(path: "partial.xlsx", sheets: [.init(name: "S", rows: [["x"]])]),
            context: context)
        #expect(output.exitStatus == 2)
        #expect(output.summary.contains("run output publication requires"))
        // The observable failure never deletes the produced file.
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("partial.xlsx").path))
    }

    @Test("temporary runs create without a durable receipt")
    func temporaryCreateSkipsPublication() async throws {
        let root = try temporaryRoot()
        let runID = UUID(), conversation = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { removeSnapshotNamespace(for: runID) }
        let tool = DocumentCreateWordTool(rootProvider: { root })
        var context = boundContext(runID: runID, conversation: conversation, root: root)
        context.temporaryReadOnly = true
        let output = try await tool.execute(
            .init(path: "temp.docx", title: "Temp", paragraphs: ["One"]),
            context: context)
        #expect(output.exitStatus == 0)
        #expect(output.outputFiles.isEmpty)
    }
}

@Suite("FloeDocuments run-output publication (office edit export)")
struct OfficeExportPublicationProducerTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("s3d-office-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func removeSnapshotNamespace(for runID: UUID) {
        guard let base = try? FloeArtifactStore.root() else { return }
        try? FileManager.default.removeItem(at: base
            .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true))
    }

    @Test("bound export publishes from the host's real committed copy")
    func boundExportPublishes() async throws {
        let root = try temporaryRoot()
        let runID = UUID(), conversation = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { removeSnapshotNamespace(for: runID) }
        let workbook = root.appendingPathComponent("sheet.xlsx")
        try OfficeDocumentBuilder.createWorkbook(
            at: workbook, sheets: [.init(name: "Inputs", rows: [["A", "1"]])])
        let revision = try FloeDigest.sha256Hex(ofFileAt: workbook)
        let status = OfficeLiveStatus(documentID: "sheet.xlsx", format: "xlsx",
                                      revisionSHA256: revision, liveSession: false,
                                      editable: true, readOnlyReason: nil,
                                      hasUnsavedChanges: false)
        let applyReceipt = OfficeCommandReceipt(documentID: "sheet.xlsx",
                                               sha256: revision, commands: [], verified: [],
                                               saved: true)
        let fake = FakeOfficeHost(
            status: status,
            receipt: applyReceipt,
            export: OfficeExportReceipt(documentID: "sheet.xlsx", relativePath: "copy.xlsx",
                                        sha256: String(repeating: "0", count: 64),
                                        byteCount: 0))
        // Opt the shared fake host into committing real bytes at the export
        // path so production publication verifies against an actual commit.
        await fake.setExportPayload(Data("floe-export-copy-bytes".utf8))
        let tool = OfficeEditTool(host: fake, workspaceRoot: { root })
        let context = ToolContext(runID: runID, toolCallID: "call-export-1",
                                  scope: .local, workspaceRootURL: root,
                                  cancellation: CancellationToken(),
                                  conversationID: conversation)
        let output = try await tool.execute(
            OfficeEditArguments(action: .export, path: "sheet.xlsx", output: "copy.xlsx"),
            context: context)
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("exported=copy.xlsx"))
        let published = try #require(output.outputFiles.first)
        #expect(output.outputFiles.count == 1)
        #expect(published.slot == "export")
        #expect(published.producerTool == "document.office.edit")
        #expect(published.displayName == "copy.xlsx")
        #expect(published.runID == runID)
        #expect(published.taskID == conversation)
        let exportedSHA = try FloeDigest.sha256Hex(ofFileAt: root.appendingPathComponent("copy.xlsx"))
        #expect(published.sha256 == exportedSHA)
        if case .verified = RunOutputSnapshotStore.verify(published) { }
        else { Issue.record("export snapshot failed verification") }
        // The export never modifies the source.
        #expect(try FloeDigest.sha256Hex(ofFileAt: workbook) == revision)
    }

    @Test("bound export with an unverifiable host copy fails observably")
    func staleHostExportFailsObservably() async throws {
        let root = try temporaryRoot()
        let runID = UUID(), conversation = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { removeSnapshotNamespace(for: runID) }
        let workbook = root.appendingPathComponent("sheet.xlsx")
        try OfficeDocumentBuilder.createWorkbook(
            at: workbook, sheets: [.init(name: "Inputs", rows: [["A", "1"]])])
        let revision = try FloeDigest.sha256Hex(ofFileAt: workbook)
        let status = OfficeLiveStatus(documentID: "sheet.xlsx", format: "xlsx",
                                      revisionSHA256: revision, liveSession: false,
                                      editable: true, readOnlyReason: nil,
                                      hasUnsavedChanges: false)
        let applyReceipt = OfficeCommandReceipt(documentID: "sheet.xlsx",
                                               sha256: revision, commands: [], verified: [],
                                               saved: true)
        // No payload set: the fake returns its synthetic receipt while no real
        // committed copy exists. A bound run must NOT advertise success.
        let fake = FakeOfficeHost(
            status: status,
            receipt: applyReceipt,
            export: OfficeExportReceipt(documentID: "sheet.xlsx", relativePath: "ghost.xlsx",
                                        sha256: String(repeating: "a", count: 64),
                                        byteCount: 11))
        let tool = OfficeEditTool(host: fake, workspaceRoot: { root })
        let context = ToolContext(runID: runID, toolCallID: "call-export-ghost",
                                  scope: .local, workspaceRootURL: root,
                                  cancellation: CancellationToken(),
                                  conversationID: conversation)
        let output = try await tool.execute(
            OfficeEditArguments(action: .export, path: "sheet.xlsx", output: "ghost.xlsx"),
            context: context)
        // The export's real commit boundary never happened: the tool must fail
        // observably (status=error) and never advertise a receipt.
        #expect(output.exitStatus == 2)
        #expect(output.summary.contains("status=error"))
        #expect(output.outputFiles.isEmpty)
    }

    @Test("legacy direct export keeps the exact pre-publication contract")
    func legacyExportUnchanged() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workbook = root.appendingPathComponent("sheet.xlsx")
        try OfficeDocumentBuilder.createWorkbook(
            at: workbook, sheets: [.init(name: "Inputs", rows: [["A", "1"]])])
        let revision = try FloeDigest.sha256Hex(ofFileAt: workbook)
        let status = OfficeLiveStatus(documentID: "sheet.xlsx", format: "xlsx",
                                      revisionSHA256: revision, liveSession: false,
                                      editable: true, readOnlyReason: nil,
                                      hasUnsavedChanges: false)
        let fake = FakeOfficeHost(
            status: status,
            receipt: OfficeCommandReceipt(documentID: "sheet.xlsx", sha256: revision,
                                          commands: [], verified: [], saved: true),
            export: OfficeExportReceipt(documentID: "sheet.xlsx", relativePath: "legacy.xlsx",
                                         sha256: String(repeating: "b", count: 64),
                                         byteCount: 7))
        let tool = OfficeEditTool(host: fake, workspaceRoot: { root })
        let output = try await tool.execute(
            OfficeEditArguments(action: .export, path: "sheet.xlsx", output: "legacy.xlsx"),
            context: ToolContext(runID: UUID(), scope: .local, workspaceRootURL: root,
                                 cancellation: CancellationToken()))
        #expect(output.exitStatus == 0)
        #expect(output.outputFiles.isEmpty)
        #expect(output.summary.contains("exported=legacy.xlsx"))
    }
}
