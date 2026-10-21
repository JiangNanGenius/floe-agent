// SPDX-License-Identifier: MPL-2.0
// FloeDocumentsTests — Office283 region export-copy qualification (guard tier).
//
// These tests exercise the REAL `OfficeRegionExport` copy preparation against
// small standards-based XLSX fixtures built by `OfficeDocumentBuilder`: sheet
// discovery in workbook tab order, honest refusals (unknown sheet, bad range,
// oversized range, destination-is-source, stale digest, non-workbook), and the
// actual print-area copy contents — scoped `_xlnm.Print_Area`, fitToPage,
// suppressed sibling sheets, activeTab, removed print titles — while the
// SOURCE package bytes and print settings stay untouched.
//
// Boundary: the pinned-engine PDF export + PDFKit PNG render of this copy is
// the App-target `OfficeDocumentRegionRenderer` native route; its real
// qualification runs in the primary hosted App build. No native engine, no
// WebKit and no App target is required here.
import Foundation
import Testing
import ZIPFoundation
import FloeCore
@testable import FloeDocuments

@Suite("FloeDocuments.OfficeRegionExport")
struct OfficeRegionExportTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-region-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func read(_ archive: Archive, path: String) throws -> Data {
        let entry = try #require(archive[path])
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return data
    }

    private func makeWorkbook(at url: URL) throws {
        // Two sheets: the target ("Data") sits at tab index 1 with non-default
        // shape (a hidden row and a hidden column), the sibling stays visible.
        try OfficeDocumentBuilder.createWorkbook(at: url, sheets: [
            .init(name: "Summary", rows: [["Total", "=Data!B2"]]),
            .init(name: "Data", rows: [
                (0..<24).map { "H\($0)" },
                ["label", "42", "hidden-col-value"],
                (0..<3).map { "T\($0)" },
            ], hiddenRows: [3], hiddenColumns: [3]),
        ])
    }

    // MARK: - Discovery

    @Test("workbookSheets lists the workbook's own tab order with visibility")
    func discoveryTabOrder() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source)
        let sha = try FloeDigest.sha256Hex(ofFileAt: source)

        let sheets = try OfficeRegionExport.workbookSheets(sourceURL: source, expectedSHA256: sha)
        #expect(sheets.count == 2)
        #expect(sheets[0].name == "Summary")
        #expect(sheets[1].name == "Data")
        #expect(sheets[0].isVisible && sheets[1].isVisible)
        #expect(!sheets[0].partPath.isEmpty && !sheets[1].partPath.isEmpty)

        // A stale expected digest refuses instead of guessing.
        #expect(throws: OfficeRegionExportError.staleSource) {
            _ = try OfficeRegionExport.workbookSheets(sourceURL: source, expectedSHA256: String(repeating: "0", count: 64))
        }
    }

    // MARK: - The copy: what it declares vs what the source keeps

    @Test("print-area copy scopes the region, suppresses siblings, leaves the source untouched")
    func printAreaCopyContents() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source)
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let copy = root.appendingPathComponent("region-copy.xlsx")

        let prepared = try OfficeRegionExport.preparePrintAreaCopy(
            sourceURL: source, destinationURL: copy, expectedSHA256: sourceSHA,
            sheetIndex: 1, sheetName: nil, cellRange: "B2:C3")
        let plan = prepared.plan
        #expect(plan.sheetIndex == 1)
        #expect(plan.sheetName == "Data")
        #expect(plan.printAreaReference == "'Data'!$B$2:$C$3")
        #expect(plan.suppressedSheetNames == ["Summary"])
        #expect(plan.madeTargetVisible == false)
        #expect(plan.setActiveTab == true)
        #expect(plan.sourceSHA256 == sourceSHA)
        #expect(plan.copySHA256 != sourceSHA)
        #expect(plan.packageEntries > 0)

        // The copy carries the scoped print area, fitToPage and the target
        // visibility; the sibling is suppressed inside the COPY only.
        let copyArchive = try Archive(url: copy, accessMode: .read)
        let copyWorkbook = String(decoding: try read(copyArchive, path: "xl/workbook.xml"), as: UTF8.self)
        #expect(copyWorkbook.contains("_xlnm.Print_Area"))
        #expect(copyWorkbook.contains("'Data'!$B$2:$C$3"))
        #expect(copyWorkbook.contains("activeTab=\"1\""))
        let sheetStates = copyWorkbook.components(separatedBy: "<sheet ")
            .dropFirst().map { $0.contains("state=\"hidden\"") || $0.contains("state=\"veryHidden\"") }
        #expect(sheetStates.count == 2)
        #expect(sheetStates[0] == true)   // Summary suppressed in the copy
        #expect(sheetStates[1] == false)  // Data stays visible

        let targetWorksheet = String(decoding: try read(copyArchive, path: plan.sheetPartPath), as: UTF8.self)
        #expect(targetWorksheet.contains("fitToPage=\"1\""))
        #expect(targetWorksheet.contains("fitToWidth=\"1\""))
        #expect(targetWorksheet.contains("fitToHeight=\"1\""))

        // The source package is byte-identical and keeps its own print state.
        #expect(try FloeDigest.sha256Hex(ofFileAt: source) == sourceSHA)
        let sourceArchive = try Archive(url: source, accessMode: .read)
        let sourceWorkbook = String(decoding: try read(sourceArchive, path: "xl/workbook.xml"), as: UTF8.self)
        #expect(!sourceWorkbook.contains("_xlnm.Print_Area"))
        #expect(!sourceWorkbook.contains("activeTab="))

        // The copy still resolves as a real workbook through the production
        // inspection route.
        let inspected = try OfficeDocumentService.inspect(url: copy)
        #expect(inspected.kind == .workbook)
        #expect(inspected.workbookPreview?.sheets.map(\.name) == ["Summary", "Data"])
    }

    @Test("a hidden target sheet is made visible in the copy only and reported")
    func hiddenTargetBecomesVisibleInCopyOnly() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try OfficeDocumentBuilder.createWorkbook(at: source, sheets: [
            .init(name: "Visible", rows: [["v"]]),
            .init(name: "Hidden", rows: [["h", "42"]], visibility: .hidden),
        ])
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let copy = root.appendingPathComponent("region-copy.xlsx")

        let prepared = try OfficeRegionExport.preparePrintAreaCopy(
            sourceURL: source, destinationURL: copy, expectedSHA256: sourceSHA,
            sheetIndex: nil, sheetName: "Hidden", cellRange: "A1:B1")
        #expect(prepared.plan.sheetIndex == 1)
        #expect(prepared.plan.madeTargetVisible == true)
        #expect(prepared.plan.suppressedSheetNames == ["Visible"])

        let copyArchive = try Archive(url: copy, accessMode: .read)
        let copyWorkbook = String(decoding: try read(copyArchive, path: "xl/workbook.xml"), as: UTF8.self)
        let copySheets = copyWorkbook.components(separatedBy: "<sheet ").dropFirst()
        let hiddenElement = try #require(copySheets.first { $0.contains("name=\"Hidden\"") })
        let visibleElement = try #require(copySheets.first { $0.contains("name=\"Visible\"") })
        #expect(!hiddenElement.prefix(while: { $0 != ">" }).contains("state="),
                "the target sheet must lose its hidden state in the copy")
        #expect(visibleElement.prefix(while: { $0 != ">" }).contains("state=\"hidden\""),
                "the suppressed sibling stays hidden in the copy")
        // The source keeps its own hidden state untouched.
        let sourceArchive = try Archive(url: source, accessMode: .read)
        let sourceWorkbook = String(decoding: try read(sourceArchive, path: "xl/workbook.xml"), as: UTF8.self)
        #expect(sourceWorkbook.contains("state=\"hidden\""))
    }

    // MARK: - Honest refusals (never a wrong-sheet or guessed render)

    @Test("unknown sheet, bad range, oversized range and source-as-destination refuse usefully")
    func honestRefusals() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source)
        let sha = try FloeDigest.sha256Hex(ofFileAt: source)

        // Unknown sheet names the available tabs.
        do {
            _ = try OfficeRegionExport.preparePrintAreaCopy(
                sourceURL: source, destinationURL: root.appendingPathComponent("c1.xlsx"),
                sheetIndex: nil, sheetName: "Nope", cellRange: "A1:B2")
            Issue.record("An unknown sheet must be refused")
        } catch let error as OfficeRegionExportError {
            guard case .unknownSheet(let requested, let available) = error else {
                Issue.record("Expected unknownSheet, got \(error)"); return
            }
            #expect(requested == "Nope")
            #expect(available == ["Summary", "Data"])
        }

        // Out-of-range tab index reports valid bounds.
        do {
            _ = try OfficeRegionExport.preparePrintAreaCopy(
                sourceURL: source, destinationURL: root.appendingPathComponent("c2.xlsx"),
                sheetIndex: 7, sheetName: nil, cellRange: "A1:B2")
            Issue.record("An out-of-range sheet index must be refused")
        } catch let error as OfficeRegionExportError {
            guard case .sheetIndexOutOfRange(let index, let count) = error else {
                Issue.record("Expected sheetIndexOutOfRange, got \(error)"); return
            }
            #expect(index == 7 && count == 2)
        }

        // Malformed range refuses with a canonical example.
        #expect(throws: OfficeRegionExportError.invalidRange(requested: "A1:", example: "A1:N30")) {
            _ = try OfficeRegionExport.preparePrintAreaCopy(
                sourceURL: source, destinationURL: root.appendingPathComponent("c3.xlsx"),
                sheetIndex: 0, sheetName: nil, cellRange: "A1:")
        }

        // Oversized range names the real limits (33 columns > 32).
        do {
            _ = try OfficeRegionExport.preparePrintAreaCopy(
                sourceURL: source, destinationURL: root.appendingPathComponent("c4.xlsx"),
                sheetIndex: 0, sheetName: nil, cellRange: "A1:AG10")
            Issue.record("An oversized range must be refused")
        } catch let error as OfficeRegionExportError {
            guard case .oversizedRange(let columns, _, _, let maxColumns, _, _) = error else {
                Issue.record("Expected oversizedRange, got \(error)"); return
            }
            #expect(columns == 33 && maxColumns == OfficeRegionExport.maximumRangeColumns)
        }

        // The source is never a destination.
        #expect(throws: OfficeRegionExportError.destinationIsSource) {
            _ = try OfficeRegionExport.preparePrintAreaCopy(
                sourceURL: source, destinationURL: source,
                sheetIndex: 0, sheetName: nil, cellRange: "A1:B2")
        }

        // A non-workbook refuses as a format error.
        let docx = root.appendingPathComponent("brief.docx")
        try OfficeDocumentBuilder.createWord(at: docx, title: "Brief", paragraphs: ["one"])
        #expect(throws: OfficeRegionExportError.unsupportedFormat("docx")) {
            _ = try OfficeRegionExport.preparePrintAreaCopy(
                sourceURL: docx, destinationURL: root.appendingPathComponent("c5.xlsx"),
                sheetIndex: 0, sheetName: nil, cellRange: "A1:B2")
        }

        // Refusals never write a destination or change the source.
        #expect(try FloeDigest.sha256Hex(ofFileAt: source) == sha)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!names.contains("c1.xlsx"))
        #expect(!names.contains("c2.xlsx"))
        #expect(!names.contains("c3.xlsx"))
        #expect(!names.contains("c4.xlsx"))
        #expect(!names.contains("c5.xlsx"))
    }

    // MARK: - Canonical cell range parsing

    @Test("cellRange parses, normalizes and renders canonical absolute forms")
    func cellRangeCanonicalForms() throws {
        let range = try #require(OfficeRegionCellRange.parse("A1:N30"))
        #expect(range.firstColumn == 1 && range.lastColumn == 14)
        #expect(range.firstRow == 1 && range.lastRow == 30)
        #expect(range.columnCount == 14 && range.rowCount == 30)
        #expect(range.cellCount == 420)
        #expect(range.canonicalReference == "A1:N30")
        #expect(range.absoluteReference == "$A$1:$N$30")

        // Case-insensitive with $ prefixes, reversed corners normalized.
        let reversed = try #require(OfficeRegionCellRange.parse("$n$30:$a$1"))
        #expect(reversed == range)

        // A single cell normalizes to a 1×1 range.
        let single = try #require(OfficeRegionCellRange.parse("B7"))
        #expect(single.firstColumn == 2 && single.lastColumn == 2)
        #expect(single.firstRow == 7 && single.lastRow == 7)
        #expect(single.canonicalReference == "B7:B7")

        // Far cells stay inside the 3-letter / 7-digit parse budget.
        let far = try #require(OfficeRegionCellRange.parse("XFD1048576"))
        #expect(far.lastColumn == 16384 && far.lastRow == 1_048_576)

        // Non-canonical shapes refuse rather than guessing.
        #expect(OfficeRegionCellRange.parse("") == nil)
        #expect(OfficeRegionCellRange.parse("A1:") == nil)
        #expect(OfficeRegionCellRange.parse("A1:B2:C3") == nil)
        #expect(OfficeRegionCellRange.parse("A0") == nil)
        #expect(OfficeRegionCellRange.parse("1A") == nil)
        #expect(OfficeRegionCellRange.parse("AAAA1") == nil)
        #expect(OfficeRegionCellRange.parse("A1B2") == nil)
        // The optional absolute-row `$` may only sit between letters and
        // digits exactly once.
        #expect(OfficeRegionCellRange.parse("A$B1") == nil)
        #expect(OfficeRegionCellRange.parse("A$$1") == nil)
        #expect(OfficeRegionCellRange.parse("A1$") == nil)
    }
}
