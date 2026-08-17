import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeDocuments

@Suite("FloeDocuments.DocumentReadSheet")
struct DocumentReadSheetToolTests {

    @Test("descriptor is read-only and file-reading")
    func descriptorContract() {
        #expect(DocumentReadSheetTool.name == "document.readSheet")
        #expect(!DocumentReadSheetTool.isSideEffecting)
        #expect(DocumentReadSheetTool.riskLabels == [.readsFiles])
    }

    @Test("empty path is rejected")
    func validation() async {
        let tool = DocumentReadSheetTool(rootProvider: { nil })
        #expect(throws: FloeError.self) {
            try tool.validate(.init(path: ""))
        }
    }

    @Test("no open workspace is an honest error result")
    func noWorkspace() async throws {
        let tool = DocumentReadSheetTool(rootProvider: { nil })
        let output = try await tool.execute(
            .init(path: "a.xlsx"),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.exitStatus == 2)
        #expect(output.summary.contains("No workspace"))
    }

    @Test("non-xlsx extension is rejected")
    func nonXlsx() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-doc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let tool = DocumentReadSheetTool(rootProvider: { root })
        let output = try await tool.execute(
            .init(path: "notes.txt"),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(output.exitStatus == 2)
        #expect(output.summary.contains("only supports .xlsx"))
    }

    @Test("document tools reject traversal and task-scope escapes")
    func workspaceBoundary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-doc-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = ToolContext(
            runID: UUID(),
            workspaceRootURL: root,
            allowedWorkspacePaths: ["allowed"],
            cancellation: CancellationToken()
        )

        let read = DocumentReadSheetTool(rootProvider: { root })
        let readOutput = try await read.execute(.init(path: "../outside.xlsx"), context: context)
        #expect(readOutput.exitStatus == 2)

        let create = DocumentCreateTool(rootProvider: { root })
        let createOutput = try await create.execute(
            .init(name: "outside.md", content: "no"), context: context
        )
        #expect(createOutput.exitStatus == 2)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.md").path))
    }
}
