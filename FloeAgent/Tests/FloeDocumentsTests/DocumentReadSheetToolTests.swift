import Foundation
import Testing
import FloeCore
import FloeTools
import ZIPFoundation
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

    @Test("reads saved shared, inline, boolean, and numeric values")
    func readsSavedValues() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-xlsx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workbookURL = root.appendingPathComponent("sample.xlsx")
        try Self.makeWorkbook(at: workbookURL)

        let tool = DocumentReadSheetTool(rootProvider: { root })
        let output = try await tool.execute(
            .init(path: "sample.xlsx"),
            context: ToolContext(
                runID: UUID(),
                workspaceRootURL: root,
                cancellation: CancellationToken()
            )
        )

        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("sheet=Data rows=2 shown=2"))
        #expect(output.summary.contains("Hello\t\tInline"))
        #expect(output.summary.contains("true\t42"))
    }

    private static func makeWorkbook(at url: URL) throws {
        let entries: [String: String] = [
            "xl/workbook.xml": #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
              <sheets><sheet name="Data" sheetId="1" r:id="rId1"/></sheets>
            </workbook>
            """#,
            "xl/_rels/workbook.xml.rels": #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
            </Relationships>
            """#,
            "xl/sharedStrings.xml": #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="1" uniqueCount="1">
              <si><r><t>Hel</t></r><r><t>lo</t></r></si>
            </sst>
            """#,
            "xl/worksheets/sheet1.xml": #"""
            <?xml version="1.0" encoding="UTF-8"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
              <sheetData>
                <row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1" t="inlineStr"><is><t>Inline</t></is></c></row>
                <row r="2"><c r="A2" t="b"><v>1</v></c><c r="B2"><v>42</v></c></row>
              </sheetData>
            </worksheet>
            """#
        ]
        let archive = try Archive(url: url, accessMode: .create)
        for (path, text) in entries.sorted(by: { $0.key < $1.key }) {
            let data = Data(text.utf8)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                provider: { position, size in
                    let lower = Int(position)
                    let upper = min(data.count, lower + size)
                    return data.subdata(in: lower..<upper)
                }
            )
        }
    }
}
