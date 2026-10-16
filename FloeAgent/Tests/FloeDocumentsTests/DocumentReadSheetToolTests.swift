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
        #expect(output.summary.contains("sheet=\"Data\" rows=2 shown=2"))
        #expect(output.summary.contains("Hello\t\tInline"))
        #expect(output.summary.contains("true\t42"))
        // Formulas display as "=FORMULA" in both readers; cached values are
        // not trusted (our own writer never emits them).
        #expect(output.summary.contains("=SUM(B2:B2)"))
        #expect(output.summary.contains("=B2*2"))
    }

    @Test("both readers discover real Chinese tabs with stable part mapping, not tab indexes")
    func discoversActualTabsAndUpdatesExactTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tabs.xlsx")
        // Deliberately reverse tab/part order and include hidden sheets.
        try Self.makeTabs(at: url, tabs: [("参数", 2, "visible"), ("预算", 1, "hidden"), ("存档", 3, "veryHidden")])
        let before = try Data(contentsOf: url)
        let context = ToolContext(runID: UUID(), workspaceRootURL: root, cancellation: CancellationToken())
        let inspect = try await OfficeInspectTool(rootProvider: { root }).execute(.init(path: "tabs.xlsx"), context: context)
        #expect(inspect.exitStatus == 0)
        let catalog = try Self.catalog(inspect.summary)
        let items = try #require(catalog["items"] as? [[String: Any]])
        #expect(items.compactMap { $0["name"] as? String } == ["参数", "预算", "存档"])
        #expect(items[0]["section"] as? String == "Sheet 2")
        #expect(items[0]["part"] as? String == "xl/worksheets/sheet2.xml")
        #expect(items[1]["visibility"] as? String == "hidden")
        #expect(items[2]["visibility"] as? String == "veryHidden")
        let reader = DocumentReadSheetTool(rootProvider: { root })
        let read = try await reader.execute(.init(path: "tabs.xlsx", sheet: "参数"), context: context)
        #expect(read.exitStatus == 0)
        #expect(read.summary.contains("value-2"))
        #expect(!read.summary.contains("value-1"))
        let readItems = try #require(Self.catalog(read.summary)["items"] as? [[String: Any]])
        #expect(readItems[0]["part"] as? String == items[0]["part"] as? String)
        let missing = try await reader.execute(.init(path: "tabs.xlsx", sheet: "Sheet 2"), context: context)
        #expect(missing.exitStatus == 2)
        #expect(missing.summary.contains("Worksheet not found"))
        #expect(!missing.summary.contains("value-"))
        #expect(try Self.catalog(missing.summary)["shown"] as? Int == 3)
        #expect(try Data(contentsOf: url) == before)

        // The discovered section locates the existing field; no ID changes.
        let snapshot = try OfficeDocumentService.inspect(url: url)
        let field = try #require(snapshot.fields.first { $0.section == items[0]["section"] as? String })
        let updated = try await OfficeUpdateTextTool(rootProvider: { root }).execute(
            .init(path: "tabs.xlsx", updates: [field.id: "edited-参数"], expectedSHA256: snapshot.sha256), context: context)
        #expect(updated.exitStatus == 0)
        let reopened = try await reader.execute(.init(path: "tabs.xlsx", sheet: "参数"), context: context)
        #expect(reopened.summary.contains("edited-参数"))
        let untouched = try await reader.execute(.init(path: "tabs.xlsx", sheet: "预算"), context: context)
        #expect(untouched.summary.contains("value-1"))
    }

    @Test("quoted, XML, backslash and control characters cannot forge catalog lines")
    func escapesNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "研发 & \"Q\" <表> '单'\\页\t行\n尾&#10;"
        try Self.makeTabs(at: root.appendingPathComponent("escaped.xlsx"), tabs: [(name, 1, "visible")])
        let context = ToolContext(runID: UUID(), workspaceRootURL: root, cancellation: CancellationToken())
        for toolOutput in [
            try await OfficeInspectTool(rootProvider: { root }).execute(.init(path: "escaped.xlsx"), context: context),
            try await DocumentReadSheetTool(rootProvider: { root }).execute(.init(path: "escaped.xlsx", sheet: name), context: context),
            try await DocumentReadSheetTool(rootProvider: { root }).execute(.init(path: "escaped.xlsx", sheet: "missing\nworksheets=forged"), context: context)
        ] {
            let items = try #require(Self.catalog(toolOutput.summary)["items"] as? [[String: Any]])
            #expect(items[0]["name"] as? String == name)
            #expect(toolOutput.summary.split(separator: "\n").filter { $0.hasPrefix("worksheets=") }.count == 1)
            #expect(!toolOutput.summary.contains("worksheets=forged"))
        }
    }

    @Test("catalog truncation stays bounded and never makes omitted sheets unreadable")
    func truncation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.makeTabs(at: root.appendingPathComponent("many.xlsx"), tabs: (1...40).map { ("表\($0)", $0, "visible") })
        let context = ToolContext(runID: UUID(), workspaceRootURL: root, cancellation: CancellationToken())
        let inspect = try await OfficeInspectTool(rootProvider: { root }).execute(.init(path: "many.xlsx"), context: context)
        let reader = DocumentReadSheetTool(rootProvider: { root })
        let read = try await reader.execute(.init(path: "many.xlsx", sheet: "表40"), context: context)
        let missing = try await reader.execute(.init(path: "many.xlsx", sheet: "不存在"), context: context)
        #expect(read.exitStatus == 0)
        #expect(read.summary.contains("value-40"))
        #expect(missing.exitStatus == 2)
        for output in [inspect, read, missing] {
            let catalog = try Self.catalog(output.summary)
            #expect(catalog["total"] as? Int == 40)
            #expect(catalog["shown"] as? Int == 32)
            #expect(catalog["truncated"] as? Bool == true)
        }
        let oversized = OfficeWorksheetToolMetadata.line([.init(name: String(repeating: "大", count: 20_000), section: "Sheet 1", part: nil, visibility: "visible")])
        #expect(oversized.utf8.count <= OfficeWorksheetToolMetadata.maximumBytes)
        #expect(try Self.catalog(oversized)["shown"] as? Int == 0)
        #expect(try Self.catalog(oversized)["truncated"] as? Bool == true)
    }

    private static func catalog(_ output: String) throws -> [String: Any] {
        let line = try #require(output.split(separator: "\n").first { $0.hasPrefix("worksheets=") })
        return try #require(JSONSerialization.jsonObject(with: Data(line.dropFirst("worksheets=".count).utf8)) as? [String: Any])
    }

    private static func makeTabs(at url: URL, tabs: [(String, Int, String)]) throws {
        func escaped(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\t", with: "&#9;").replacingOccurrences(of: "\n", with: "&#10;")
        }
        let sheetElements = tabs.map { "<sheet name=\"\(escaped($0.0))\" sheetId=\"\($0.1)\" r:id=\"rId\($0.1)\" state=\"\($0.2)\"/>" }.joined()
        let relationships = tabs.map { "<Relationship Id=\"rId\($0.1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0.1).xml\"/>" }.joined()
        var entries = [
            "xl/workbook.xml": "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>\(sheetElements)</sheets></workbook>",
            "xl/_rels/workbook.xml.rels": "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(relationships)</Relationships>"
        ]
        for (_, part, _) in tabs {
            entries["xl/worksheets/sheet\(part).xml"] = "<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>value-\(part)</t></is></c></row></sheetData></worksheet>"
        }
        let archive = try Archive(url: url, accessMode: .create)
        for (path, value) in entries {
            let data = Data(value.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { offset, count in
                data.subdata(in: Int(offset)..<min(data.count, Int(offset) + count))
            }
        }
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
                <row r="2"><c r="A2" t="b"><v>1</v></c><c r="B2"><v>42</v></c><c r="C2"><f>SUM(B2:B2)</f></c><c r="D2"><f>B2*2</f><v>84</v></c></row>
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
