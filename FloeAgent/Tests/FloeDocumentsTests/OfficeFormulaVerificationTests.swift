// FloeDocumentsTests — persisted cached formula-result verification.
//
// These tests build real OOXML packages in memory and read them back with the
// production snapshot parser; nothing is mocked.

import Foundation
import Testing
import ZIPFoundation
import FloeCore
@testable import FloeDocuments

@Suite("Office formula cached-result verification")
struct OfficeFormulaVerificationTests {
    // MARK: - Package fixtures

    private func temporaryURL(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-formula-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(name)
    }

    private func writePackage(_ url: URL, entries: [String: String]) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (path, value) in entries {
            try archive.addFloeEntry(path: path, data: Data(value.utf8))
        }
    }

    /// Minimal two-sheet workbook. `sheets` maps sheet name → sheetData XML.
    private func workbook(_ sheets: [(name: String, data: String)],
                          styles: String = #"<cellXfs count="1"><xf numFmtId="0"/></cellXfs>"#,
                          shared: [String] = []) throws -> URL {
        let url = try temporaryURL("book.xlsx")
        var entries: [String: String] = [
            "[Content_Types].xml": #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>"#,
            "xl/workbook.xml": #"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>"# +
                sheets.enumerated().map { index, sheet in
                    #"<sheet name="\#(sheet.name)" sheetId="\#(index + 1)" r:id="rId\#(index + 1)"/>"#
                }.joined() + "</sheets></workbook>",
            "xl/_rels/workbook.xml.rels": #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"# +
                sheets.enumerated().map { index, _ in
                    #"<Relationship Id="rId\#(index + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#(index + 1).xml"/>"#
                }.joined() + "</Relationships>",
            "xl/styles.xml": #"<styleSheet>\#(styles)</styleSheet>"#,
        ]
        for (index, sheet) in sheets.enumerated() {
            entries["xl/worksheets/sheet\(index + 1).xml"] =
                #"<worksheet><sheetData>\#(sheet.data)</sheetData></worksheet>"#
        }
        if !shared.isEmpty {
            entries["xl/sharedStrings.xml"] = #"<sst>\#(shared.map { "<si><t>\($0)</t></si>" }.joined())</sst>"#
        }
        try writePackage(url, entries: entries)
        return url
    }

    // MARK: - Evaluator behaviour

    @Test("SUM over a same-sheet range verifies against the persisted cache")
    func sumVerified() throws {
        let url = try workbook([(name: "Sheet1", data:
            #"<row r="1"><c r="A1"><v>1</v></c><c r="B1"><f>SUM(A1:A3)</f><v>6</v></c></row>"#
            + #"<row r="2"><c r="A2"><v>2</v></c></row><row r="3"><c r="A3"><v>3</v></c></row>"#)])
        let snapshot = try OfficeOutputSnapshot.capture(url: url)
        #expect(snapshot.formulaCells.count == 1)
        let report = OfficeFormulaVerifier.verify(snapshot: snapshot)
        #expect(report.isClean)
        #expect(report.verifiedCount == 1)
        #expect(report.facts.contains { $0.contains("formula=Sheet1!B1") && $0.contains("verified") })
        try OfficeOutputValidator.verify(before: nil, after: snapshot,
                                         expectations: [.excelFormulaResultsRecalculated])
    }

    @Test("a stale SUM cache is reported and fails recalculation verification")
    func staleSumCache() throws {
        let url = try workbook([(name: "Sheet1", data:
            #"<row r="1"><c r="A1"><v>1</v></c><c r="B1"><f>SUM(A1:A3)</f><v>5</v></c></row>"#
            + #"<row r="2"><c r="A2"><v>2</v></c></row><row r="3"><c r="A3"><v>3</v></c></row>"#)])
        let snapshot = try OfficeOutputSnapshot.capture(url: url)
        let report = OfficeFormulaVerifier.verify(snapshot: snapshot)
        #expect(!report.isClean)
        #expect(report.staleCount == 1)
        #expect(report.failures.first?.contains("B1") == true)
        #expect(report.failures.first?.contains("6") == true)
        #expect(throws: OfficeOutputValidationError.self) {
            try OfficeOutputValidator.verify(before: nil, after: snapshot,
                                             expectations: [.excelFormulaResultsRecalculated])
        }
    }

    @Test("cross-sheet SUM resolves the referenced sheet's persisted values")
    func crossSheetSum() throws {
        let url = try workbook([
            (name: "Data", data: #"<row r="1"><c r="A1"><v>10</v></c><c r="B1"><v>7</v></c></row>"#),
            (name: "Report", data: #"<row r="1"><c r="C1"><f>SUM(Data!A1:B1)</f><v>17</v></c></row>"#),
        ])
        let snapshot = try OfficeOutputSnapshot.capture(url: url)
        #expect(snapshot.sheetNamesInOrder == ["Data", "Report"])
        #expect(snapshot.sheetNameByMember["xl/worksheets/sheet1.xml"] == "Data")
        let report = OfficeFormulaVerifier.verify(snapshot: snapshot)
        #expect(report.isClean)
        #expect(report.verifiedCount == 1)

        // The same formula with a stale saved result must fail.
        let stale = try workbook([
            (name: "Data", data: #"<row r="1"><c r="A1"><v>10</v></c><c r="B1"><v>7</v></c></row>"#),
            (name: "Report", data: #"<row r="1"><c r="C1"><f>SUM(Data!A1:B1)</f><v>16</v></c></row>"#),
        ])
        let staleSnapshot = try OfficeOutputSnapshot.capture(url: stale)
        #expect(OfficeFormulaVerifier.verify(snapshot: staleSnapshot).staleCount == 1)
    }

    @Test("error formulas verify the persisted error code, not a number")
    func errorFormula() throws {
        let url = try workbook([(name: "Sheet1", data:
            #"<row r="1"><c r="A1"><v>1</v></c><c r="B1" t="e"><f>A1/0</f><v>#DIV/0!</v></c></row>"#)])
        let snapshot = try OfficeOutputSnapshot.capture(url: url)
        let report = OfficeFormulaVerifier.verify(snapshot: snapshot)
        #expect(report.isClean)
        #expect(report.errorCount == 1)

        // A number persisted where the formula evaluates to #DIV/0! is stale.
        let wrong = try workbook([(name: "Sheet1", data:
            #"<row r="1"><c r="A1"><v>1</v></c><c r="B1"><f>A1/0</f><v>0</v></c></row>"#)])
        let wrongSnapshot = try OfficeOutputSnapshot.capture(url: wrong)
        #expect(OfficeFormulaVerifier.verify(snapshot: wrongSnapshot).staleCount == 1)
    }

    @Test("an unchanged-but-consistent formula stays verified across recalculation")
    func unchangedValid() throws {
        let data = #"<row r="1"><c r="A1"><v>2</v></c><c r="B1"><f>A1*3</f><v>6</v></c></row>"#
        let before = try OfficeOutputSnapshot.capture(url: try workbook([(name: "Sheet1", data: data)]))
        let after = try OfficeOutputSnapshot.capture(url: try workbook([(name: "Sheet1", data: data)]))
        // Byte-identical save: the formula was already correct and stays correct.
        try OfficeOutputValidator.verify(before: before, after: after,
                                         expectations: [.excelFormulaResultsRecalculated])
        let report = OfficeFormulaVerifier.verify(snapshot: after)
        #expect(report.verifiedCount == 1)
        #expect(report.isClean)
    }

    @Test("a formula without a persisted cache fails even when its shape is evaluable")
    func missingCache() throws {
        let url = try workbook([(name: "Sheet1", data:
            #"<row r="1"><c r="A1"><v>1</v></c><c r="B1"><f>SUM(A1:A2)</f></c></row>"#)])
        let snapshot = try OfficeOutputSnapshot.capture(url: url)
        let report = OfficeFormulaVerifier.verify(snapshot: snapshot)
        #expect(report.missingCount == 1)
        #expect(!report.isClean)
        #expect(report.failures.first?.contains("no persisted cached result") == true)
    }

    @Test("an unsupported formula shape is reported, never claimed verified")
    func unsupportedShape() throws {
        let url = try workbook([(name: "Sheet1", data:
            #"<row r="1"><c r="A1"><v>1</v></c><c r="B1"><f>VLOOKUP(A1,A1:B2,2,FALSE)</f><v>7</v></c></row>"#)])
        let snapshot = try OfficeOutputSnapshot.capture(url: url)
        let report = OfficeFormulaVerifier.verify(snapshot: snapshot)
        #expect(report.isClean)             // nothing was contradicted...
        #expect(report.verifiedCount == 0)  // ...and nothing was verified either
        #expect(report.unverifiedCount == 1)
        #expect(report.summary.contains("unverifiedShapes=1"))
        // The expectation passes because the cache exists; the fact states the
        // shape was not evaluated. A missing cache for an unsupported shape is
        // still a failure.
        try OfficeOutputValidator.verify(before: nil, after: snapshot,
                                         expectations: [.excelFormulaResultsRecalculated])
        let missing = try workbook([(name: "Sheet1", data:
            #"<row r="1"><c r="A1"><v>1</v></c><c r="B1"><f>VLOOKUP(A1,A1:B2,2,FALSE)</f></c></row>"#)])
        #expect(OfficeFormulaVerifier.verify(snapshot: try OfficeOutputSnapshot.capture(url: missing)).missingCount == 1)
    }

    @Test("direct references and string results compare exactly")
    func referencesAndStrings() throws {
        let url = try workbook([(name: "Sheet1", data:
            #"<row r="1"><c r="A1"><v>42</v></c><c r="B1"><f>A1</f><v>42</v></c>"#
            + #"<c r="C1" t="str"><f>"hi"</f><v>hi</v></c></row>"#)])
        let snapshot = try OfficeOutputSnapshot.capture(url: url)
        let report = OfficeFormulaVerifier.verify(snapshot: snapshot)
        #expect(report.verifiedCount == 2)
        #expect(report.isClean)

        let wrongString = try workbook([(name: "Sheet1", data:
            #"<row r="1"><c r="C1" t="str"><f>"hi"</f><v>bye</v></c></row>"#)])
        #expect(OfficeFormulaVerifier.verify(snapshot: try OfficeOutputSnapshot.capture(url: wrongString)).staleCount == 1)
    }

    @Test("a workbook without formula cells reports an honest no-op recalculation")
    func noFormulas() throws {
        let url = try workbook([(name: "Sheet1", data:
            #"<row r="1"><c r="A1"><v>1</v></c></row>"#)])
        let snapshot = try OfficeOutputSnapshot.capture(url: url)
        let report = OfficeFormulaVerifier.verify(snapshot: snapshot)
        #expect(report.outcomes.isEmpty)
        #expect(report.isClean)
        #expect(report.facts.contains { $0.contains("noFormulaCells") })
        try OfficeOutputValidator.verify(before: nil, after: snapshot,
                                         expectations: [.excelFormulaResultsRecalculated])
    }

    @Test("recalculation expectation replaces the old requested-only predicate")
    func expectationIsReal() {
        let expectations = OfficeOutputExpectation.forCommand(.excelRecalculate, before: nil)
        #expect(expectations == [.excelFormulaResultsRecalculated])
    }

    @Test("a truncated dependency context fails closed instead of guessing")
    func truncatedContext() throws {
        // 1500 numeric cells exceed the bounded formula-context budget; the
        // checker must not claim the SUM cache was verified.
        let cells = (1...1_500).map { #"<c r="A\#($0)"><v>1</v></c>"# }.joined()
        let url = try workbook([(name: "Sheet1", data:
            "<row r=\"1\">\(cells)</row>"
            + #"<row r="2"><c r="B1"><f>SUM(A1:A1500)</f><v>1499</v></c></row>"#)],
            styles: #"<cellXfs count="1"><xf numFmtId="0"/></cellXfs>"#)
        let snapshot = try OfficeOutputSnapshot.capture(url: url)
        let report = OfficeFormulaVerifier.verify(snapshot: snapshot)
        #expect(report.verifiedCount == 0)
        #expect(report.unverifiedCount == 1)
    }
}
