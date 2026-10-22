// SPDX-License-Identifier: MPL-2.0
// FloeDocumentsTests — Office PDF print-plan and print-copy qualification.
//
// The fixtures are synthetic, public-safe workbooks built in the test. They
// deliberately mirror the geometry that motivated build 283 without using
// the user's data: three sheets (one very hidden), a worksheet dimension that
// covers only A1:B1, and a drawing anchored from F6 to R37 so the extent
// resolver must read the drawing member instead of the nonempty cells. Other
// cases cover print areas/titles preservation, every fit mode, paper codes,
// margin presets, exact-range refusal instead of clamping, Excel worksheet
// bounds (not the assistant PNG limits), active-tab selection and
// byte-for-byte preservation of unrelated members.
//
// Boundary: these are pure `FloeDocuments` checks. The real pinned-engine PDF
// output (page geometry, ink not split horizontally, actual full-sheet and
// workbook page composition) is the App/native gate owned by root; nothing
// here claims that a PDF was rendered.
import Foundation
import Testing
import ZIPFoundation
import FloeCore
@testable import FloeDocuments

@Suite("FloeDocuments.OfficePrintCopy")
struct OfficePrintCopyTests {
    // MARK: - Fixture

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-print-copy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func member(_ archive: Archive, _ path: String) throws -> Data {
        guard let entry = archive[path] else {
            throw OfficeDocumentError.missingEntry(path)
        }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return data
    }

    private func xmlString(_ archive: Archive, _ path: String) throws -> String {
        String(decoding: try member(archive, path), as: UTF8.self)
    }

    private static let pngBytes = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    ])

    private func makeWorkbook(at url: URL,
                              includeDefinedNames: Bool = true,
                              dataDimension: String? = "A1:B1",
                              includeDrawing: Bool = true,
                              oneCellAnchor: Bool = false,
                              dataPrintOptions: String? = nil) throws {
        let workbook: String = {
            let names = includeDefinedNames ? """
            <definedNames>
              <definedName name="_xlnm.Print_Area" localSheetId="1">'Data'!$B$2:$C$3</definedName>
              <definedName name="_xlnm.Print_Titles" localSheetId="1">'Data'!$1:$1</definedName>
              <definedName name="GrandTotal">Summary!$A$1</definedName>
            </definedNames>
            """ : ""
            return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
              <bookViews><workbookView activeTab="0"/></bookViews>
              <sheets>
                <sheet name="Summary" sheetId="1" r:id="rId1"/>
                <sheet name="Data" sheetId="2" r:id="rId2"/>
                <sheet name="Hidden" sheetId="3" r:id="rId3" state="veryHidden"/>
              </sheets>
              \(names)
              <calcPr calcId="0"/>
            </workbook>
            """
        }()
        let rels = """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
          <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet3.xml"/>
          <Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """
        let summary = """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <dimension ref="A1:B1"/>
          <sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Total</t></is></c><c r="B1"><v>3</v></c></row></sheetData>
        </worksheet>
        """
        let dataSheet: String = {
            let dimension = dataDimension.map { "<dimension ref=\"\($0)\"/>" } ?? ""
            let drawing = includeDrawing ? "<drawing r:id=\"rId1\"/>" : ""
            // Schema position: after the sheet content/hyperlinks, before
            // `pageMargins`. Tests inject saved print options here to prove
            // the gridlines writer preserves the other declared flags.
            let printOptions = dataPrintOptions ?? ""
            return """
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
              <sheetPr><pageSetUpPr fitToPage="0"/></sheetPr>
              \(dimension)
              <sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>label</t></is></c><c r="B1" t="inlineStr"><is><t>value</t></is></c></row></sheetData>
              \(printOptions)
              <pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>
              <pageSetup paperSize="9" orientation="portrait" scale="100"/>
              \(drawing)
            </worksheet>
            """
        }()
        let hidden = """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <dimension ref="A1:A1"/>
          <sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>secret</t></is></c></row></sheetData>
        </worksheet>
        """
        let sheetRels = """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing" Target="../drawings/drawing1.xml"/>
        </Relationships>
        """
        let drawingAnchor = oneCellAnchor ? """
        <xdr:oneCellAnchor>
          <xdr:from><xdr:col>3</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>3</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from>
          <xdr:ext cx="914400" cy="914400"/>
          <xdr:clientData/>
        </xdr:oneCellAnchor>
        """ : ""
        let drawing = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
          <xdr:twoCellAnchor editAs="oneCell">
            <xdr:from><xdr:col>5</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>5</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from>
            <xdr:to><xdr:col>17</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>36</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to>
            <xdr:pic>
              <xdr:nvPicPr><xdr:cNvPr id="2" name="Ink 1"/><xdr:cNvPicPr/></xdr:nvPicPr>
              <xdr:blipFill><a:blip xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" r:embed="rId1"/></xdr:blipFill>
              <xdr:spPr/>
            </xdr:pic>
            <xdr:clientData/>
          </xdr:twoCellAnchor>
          \(drawingAnchor)
        </xdr:wsDr>
        """
        let drawingRels = """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image1.png"/>
        </Relationships>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Default Extension="png" ContentType="image/png"/>
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
          <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
          <Override PartName="/xl/worksheets/sheet3.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
          <Override PartName="/xl/drawings/drawing1.xml" ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/>
        </Types>
        """
        let rootRels = """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """
        let styles = """
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <fonts count="1"><font><sz val="11"/><name val="Arial"/></font></fonts>
          <fills count="1"><fill><patternFill patternType="none"/></fill></fills>
          <borders count="1"><border/></borders>
          <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
          <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>
          <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
        </styleSheet>
        """
        let members: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRels.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(rels.utf8)),
            ("xl/worksheets/sheet1.xml", Data(summary.utf8)),
            ("xl/worksheets/sheet2.xml", Data(dataSheet.utf8)),
            ("xl/worksheets/sheet3.xml", Data(hidden.utf8)),
            ("xl/worksheets/_rels/sheet2.xml.rels", Data(sheetRels.utf8)),
            ("xl/drawings/drawing1.xml", Data(drawing.utf8)),
            ("xl/drawings/_rels/drawing1.xml.rels", Data(drawingRels.utf8)),
            ("xl/media/image1.png", Self.pngBytes),
            ("xl/styles.xml", Data(styles.utf8)),
        ]
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in members {
            try archive.addFloeEntry(path: path, data: data)
        }
        _ = try OfficeDocumentService.inspect(url: url)
    }

    // MARK: - Content extent

    @Test("extent reads the drawing anchors beyond the cell dimension")
    func extentIncludesDrawingAnchors() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source)
        let sha = try FloeDigest.sha256Hex(ofFileAt: source)

        let extent = try OfficePDFContentExtent.resolve(sourceURL: source,
                                                         sheetName: "Data",
                                                         expectedSHA256: sha)
        #expect(extent.dimensionReference == "A1:B1")
        #expect(extent.cellRangeReference == "A1:R37")
        #expect(extent.firstColumn == 1 && extent.lastColumn == 18)
        #expect(extent.firstRow == 1 && extent.lastRow == 37)
        #expect(extent.drawingAnchorCount == 1)
        #expect(extent.resolvedDrawingAnchorCount == 1)
        #expect(extent.unresolvedAnchorCount == 0)
        #expect(extent.includesDrawings)
        #expect(extent.isResolved && extent.isComplete)

        let summary = try OfficePDFContentExtent.resolve(sourceURL: source, sheetName: "Summary")
        #expect(summary.cellRangeReference == "A1:B1")
        #expect(summary.drawingAnchorCount == 0)

        #expect(throws: OfficePDFPlanError.englishUnknownSheet) {
            _ = try OfficePDFContentExtent.resolve(sourceURL: source, sheetName: "Missing")
        }
    }

    @Test("an unresolvable dimension is reported unknown, never inferred from anchors")
    func extentWithoutDimensionIsUnknown() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source, dataDimension: nil)
        let extent = try OfficePDFContentExtent.resolve(sourceURL: source, sheetName: "Data")
        #expect(extent.isResolved == false)
        #expect(extent.cellRangeReference == nil)
        #expect(extent.dimensionReference == nil)
        // The anchors are still counted, but they never fabricate a range.
        #expect(extent.drawingAnchorCount == 1)
    }

    @Test("a one-cell anchor contributes only its own cell and stays incomplete")
    func oneCellAnchorIsUnresolvedSpan() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source, oneCellAnchor: true)
        let extent = try OfficePDFContentExtent.resolve(sourceURL: source, sheetName: "Data")
        #expect(extent.cellRangeReference == "A1:R37")
        #expect(extent.drawingAnchorCount == 2)
        #expect(extent.resolvedDrawingAnchorCount == 1)
        #expect(extent.unresolvedAnchorCount == 1)
        #expect(extent.isComplete == false)
    }

    // MARK: - Copy scopes

    @Test("full-sheet copy suppresses siblings, removes print areas and keeps print titles")
    func singleSheetFullContent() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source)
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let sourceBytes = try Data(contentsOf: source)
        let destination = root.appendingPathComponent("copy.xlsx")

        let plan = OfficePDFPrintPlan(scope: .sheet(name: "Data", cellRange: nil))
        let copyPlan = try OfficePrintCopy.prepare(sourceURL: source,
                                                   destinationURL: destination,
                                                   expectedSHA256: sourceSHA,
                                                   plan: plan)
        #expect(copyPlan.targetSheetName == "Data")
        #expect(copyPlan.targetSheetIndex == 1)
        #expect(copyPlan.printedSheetNames == ["Data"])
        #expect(copyPlan.suppressedSheetNames == ["Summary", "Hidden"])
        #expect(copyPlan.printAreaReference == nil)
        #expect(copyPlan.removedPrintAreas == 1)
        #expect(copyPlan.removedPrintTitles == 0)
        #expect(copyPlan.preservedPrintTitles == 1)
        #expect(copyPlan.madeTargetVisible == false)
        #expect(copyPlan.setActiveTab == true)
        #expect(copyPlan.drawingPartsPreserved == true)
        #expect(copyPlan.drawingPartPaths == ["xl/drawings/drawing1.xml"])
        #expect(try FloeDigest.sha256Hex(ofFileAt: source) == sourceSHA)
        #expect(try Data(contentsOf: source) == sourceBytes)

        let copy = try Archive(url: destination, accessMode: .read)
        let workbook = try xmlString(copy, "xl/workbook.xml")
        #expect(copyPlan.copySHA256 == (try FloeDigest.sha256Hex(ofFileAt: destination)))
        #expect(workbook.contains("activeTab=\"1\""))
        #expect(workbook.contains("_xlnm.Print_Titles"))
        #expect(!workbook.contains("_xlnm.Print_Area"))
        #expect(workbook.contains("name=\"GrandTotal\""))
        let sheetStates = sheetStates(in: workbook)
        #expect(sheetStates == ["hidden", "visible", "veryHidden"])

        // Unrelated members are byte-identical in the copy.
        let sourceArchive = try Archive(url: source, accessMode: .read)
        for path in ["xl/drawings/drawing1.xml",
                     "xl/drawings/_rels/drawing1.xml.rels",
                     "xl/media/image1.png",
                     "xl/styles.xml",
                     "xl/worksheets/_rels/sheet2.xml.rels",
                     "[Content_Types].xml"] {
            #expect(try member(copy, path) == member(sourceArchive, path), "member \(path) changed")
        }
    }

    @Test("explicit range writes exactly one print area and removes print titles")
    func singleSheetRange() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source)
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let destination = root.appendingPathComponent("copy.xlsx")

        let plan = OfficePDFPrintPlan(scope: .sheet(name: "Data", cellRange: "F6:R37"))
        let copyPlan = try OfficePrintCopy.prepare(sourceURL: source,
                                                   destinationURL: destination,
                                                   expectedSHA256: sourceSHA,
                                                   plan: plan)
        #expect(copyPlan.printAreaReference == "'Data'!$F$6:$R$37")
        #expect(copyPlan.removedPrintAreas == 1)
        #expect(copyPlan.removedPrintTitles == 1)
        #expect(copyPlan.preservedPrintTitles == 0)
        #expect(copyPlan.setActiveTab == true)
        #expect(try FloeDigest.sha256Hex(ofFileAt: source) == sourceSHA)

        let copy = try Archive(url: destination, accessMode: .read)
        let workbook = try xmlString(copy, "xl/workbook.xml")
        #expect(workbook.components(separatedBy: "_xlnm.Print_Area").count == 2)
        #expect(workbook.contains("localSheetId=\"1\">'Data'!$F$6:$R$37</definedName>"))
        #expect(!workbook.contains("_xlnm.Print_Titles"))
        #expect(sheetStates(in: workbook) == ["hidden", "visible", "veryHidden"])
    }

    @Test("all visible sheets keeps hidden state and prints each visible sheet in full")
    func allVisibleSheets() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source)
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let destination = root.appendingPathComponent("copy.xlsx")

        let plan = OfficePDFPrintPlan(scope: .allVisibleSheets)
        let copyPlan = try OfficePrintCopy.prepare(sourceURL: source,
                                                   destinationURL: destination,
                                                   expectedSHA256: sourceSHA,
                                                   plan: plan)
        #expect(copyPlan.printedSheetNames == ["Summary", "Data"])
        #expect(copyPlan.suppressedSheetNames == ["Hidden"])
        #expect(copyPlan.printAreaReference == nil)
        #expect(copyPlan.removedPrintAreas == 1)
        #expect(copyPlan.removedPrintTitles == 0)
        #expect(copyPlan.preservedPrintTitles == 1)
        #expect(copyPlan.setActiveTab == false)

        let copy = try Archive(url: destination, accessMode: .read)
        let workbook = try xmlString(copy, "xl/workbook.xml")
        #expect(sheetStates(in: workbook) == ["visible", "visible", "veryHidden"])
        #expect(!workbook.contains("_xlnm.Print_Area"))
        #expect(workbook.contains("_xlnm.Print_Titles"))
    }

    @Test("document settings preserve print areas, titles, visibility and active tab")
    func documentSettingsArePreserved() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source)
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let sourceArchive = try Archive(url: source, accessMode: .read)
        let destination = root.appendingPathComponent("copy.xlsx")

        let plan = OfficePDFPrintPlan(scope: .documentSettings)
        let copyPlan = try OfficePrintCopy.prepare(sourceURL: source,
                                                   destinationURL: destination,
                                                   expectedSHA256: sourceSHA,
                                                   plan: plan)
        #expect(copyPlan.preservedPrintAreas == 1)
        #expect(copyPlan.preservedPrintTitles == 1)
        #expect(copyPlan.printAreaReference == nil)
        #expect(copyPlan.changedSheetParts.isEmpty)
        #expect(copyPlan.setActiveTab == false)

        let copy = try Archive(url: destination, accessMode: .read)
        #expect(try member(copy, "xl/workbook.xml") == member(sourceArchive, "xl/workbook.xml"))
        #expect(try member(copy, "xl/worksheets/sheet1.xml") == member(sourceArchive, "xl/worksheets/sheet1.xml"))
        #expect(try member(copy, "xl/worksheets/sheet2.xml") == member(sourceArchive, "xl/worksheets/sheet2.xml"))
    }

    @Test("a hidden target is made visible in the copy only")
    func hiddenTargetBecomesVisible() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source)
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let destination = root.appendingPathComponent("copy.xlsx")

        let plan = OfficePDFPrintPlan(scope: .sheet(name: "Hidden", cellRange: nil))
        let copyPlan = try OfficePrintCopy.prepare(sourceURL: source,
                                                   destinationURL: destination,
                                                   expectedSHA256: sourceSHA,
                                                   plan: plan)
        #expect(copyPlan.madeTargetVisible == true)
        #expect(copyPlan.setActiveTab == true)
        #expect(copyPlan.printedSheetNames == ["Hidden"])
        #expect(copyPlan.suppressedSheetNames == ["Summary", "Data"])

        let copy = try Archive(url: destination, accessMode: .read)
        let workbook = try xmlString(copy, "xl/workbook.xml")
        #expect(sheetStates(in: workbook) == ["hidden", "hidden", "visible"])
        #expect(workbook.contains("activeTab=\"2\""))

        // The source keeps its very-hidden state.
        let sourceArchive = try Archive(url: source, accessMode: .read)
        #expect(sheetStates(in: try xmlString(sourceArchive, "xl/workbook.xml"))
                == ["visible", "visible", "veryHidden"])
    }

    // MARK: - Page setup

    @Test("fit modes write consistent pageSetUpPr and pageSetup attributes")
    func fitModes() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source)
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)

        func prepare(_ fit: OfficePDFFit, name: String) throws -> String {
            let destination = root.appendingPathComponent("copy-\(name).xlsx")
            let plan = OfficePDFPrintPlan(
                scope: .sheet(name: "Data", cellRange: "B2:C3"),
                pageSetup: OfficePDFPageSetup(fit: fit))
            _ = try OfficePrintCopy.prepare(sourceURL: source,
                                            destinationURL: destination,
                                            expectedSHA256: sourceSHA,
                                            plan: plan)
            return try xmlString(try Archive(url: destination, accessMode: .read),
                                 "xl/worksheets/sheet2.xml")
        }

        let fitWidth = try prepare(.fitToWidth, name: "fit-width")
        #expect(fitWidth.contains("<pageSetUpPr fitToPage=\"1\"/>"))
        #expect(fitWidth.contains("fitToWidth=\"1\""))
        #expect(fitWidth.contains("fitToHeight=\"0\""))
        #expect(!fitWidth.contains("scale="))

        let onePage = try prepare(.fitToOnePage, name: "one-page")
        #expect(onePage.contains("<pageSetUpPr fitToPage=\"1\"/>"))
        #expect(onePage.contains("fitToWidth=\"1\""))
        #expect(onePage.contains("fitToHeight=\"1\""))
        #expect(!onePage.contains("scale="))

        let actual = try prepare(.actualSize, name: "actual")
        #expect(actual.contains("<pageSetUpPr fitToPage=\"0\"/>"))
        #expect(actual.contains("scale=\"100\""))
        #expect(!actual.contains("fitToWidth="))
        #expect(!actual.contains("fitToHeight="))
    }

    @Test("paper codes, orientation and margin presets are written exactly")
    func paperOrientationMargins() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source)
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)

        let expectedCodes: [(OfficePDFPaper, String)] = [
            (.a4, "9"), (.a3, "8"), (.letter, "1"), (.legal, "5"),
        ]
        for (paper, code) in expectedCodes {
            let destination = root.appendingPathComponent("copy-\(paper.rawValue).xlsx")
            let plan = OfficePDFPrintPlan(
                scope: .sheet(name: "Data", cellRange: "B2:C3"),
                pageSetup: OfficePDFPageSetup(paper: paper,
                                              orientation: .landscape,
                                              fit: .fitToOnePage,
                                              margins: .narrow))
            _ = try OfficePrintCopy.prepare(sourceURL: source,
                                            destinationURL: destination,
                                            expectedSHA256: sourceSHA,
                                            plan: plan)
            let worksheet = try xmlString(try Archive(url: destination, accessMode: .read),
                                          "xl/worksheets/sheet2.xml")
            #expect(worksheet.contains("paperSize=\"\(code)\""))
            #expect(worksheet.contains("orientation=\"landscape\""))
            #expect(worksheet.contains("left=\"0.25\""))
            #expect(worksheet.contains("right=\"0.25\""))
            #expect(worksheet.contains("header=\"0.3\""))
        }

        // Wide margins and margins-only (pageSetup untouched).
        let destination = root.appendingPathComponent("copy-margins.xlsx")
        let marginsPlan = OfficePDFPrintPlan(
            scope: .sheet(name: "Data", cellRange: nil),
            pageSetup: OfficePDFPageSetup(margins: .wide))
        _ = try OfficePrintCopy.prepare(sourceURL: source,
                                        destinationURL: destination,
                                        expectedSHA256: sourceSHA,
                                        plan: marginsPlan)
        let worksheet = try xmlString(try Archive(url: destination, accessMode: .read),
                                     "xl/worksheets/sheet2.xml")
        #expect(worksheet.contains("left=\"1\""))
        #expect(worksheet.contains("top=\"1\""))
        #expect(worksheet.contains("header=\"0.5\""))
        // Existing pageSetup scale is preserved because fit was not chosen.
        #expect(worksheet.contains("scale=\"100\""))
    }

    @Test("page setup can be inserted before drawing in a worksheet that lacks it")
    func pageSetupInsertionOrder() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source)
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let destination = root.appendingPathComponent("copy.xlsx")

        let plan = OfficePDFPrintPlan(
            scope: .sheet(name: "Data", cellRange: nil),
            pageSetup: OfficePDFPageSetup(paper: .a4, fit: .fitToOnePage))
        _ = try OfficePrintCopy.prepare(sourceURL: source,
                                        destinationURL: destination,
                                        expectedSHA256: sourceSHA,
                                        plan: plan)
        let worksheet = try xmlString(try Archive(url: destination, accessMode: .read),
                                     "xl/worksheets/sheet2.xml")
        let setupIndex = try #require(worksheet.range(of: "<pageSetup"))
        let drawingIndex = try #require(worksheet.range(of: "<drawing"))
        #expect(setupIndex.lowerBound < drawingIndex.lowerBound)
        let marginsIndex = try #require(worksheet.range(of: "<pageMargins"))
        #expect(marginsIndex.lowerBound < setupIndex.lowerBound)
    }

    // MARK: - Range bounds

    @Test("a valid full Excel range is accepted without PNG region limits")
    func fullExcelBoundsAreAccepted() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source)
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let destination = root.appendingPathComponent("copy.xlsx")

        let plan = OfficePDFPrintPlan(scope: .sheet(name: "Data",
                                                    cellRange: "A1:XFD1048576"))
        let copyPlan = try OfficePrintCopy.prepare(sourceURL: source,
                                                   destinationURL: destination,
                                                   expectedSHA256: sourceSHA,
                                                   plan: plan)
        #expect(copyPlan.printAreaReference == "'Data'!$A$1:$XFD$1048576")
        let workbook = try xmlString(try Archive(url: destination, accessMode: .read),
                                     "xl/workbook.xml")
        #expect(workbook.contains("'Data'!$A$1:$XFD$1048576"))
    }

    @Test("invalid ranges and unknown sheets are refused, never clamped")
    func invalidRangeRefusals() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source)
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)

        func refuse(_ scope: OfficePDFScope) {
            let destination = root.appendingPathComponent("refused-\(UUID().uuidString).xlsx")
            #expect(throws: (any Error).self) {
                _ = try OfficePrintCopy.prepare(sourceURL: source,
                                                destinationURL: destination,
                                                expectedSHA256: sourceSHA,
                                                plan: OfficePDFPrintPlan(scope: scope))
            }
            #expect(FileManager.default.fileExists(atPath: destination.path) == false)
        }

        refuse(.sheet(name: "Data", cellRange: "A0:B1"))
        refuse(.sheet(name: "Data", cellRange: "XFE1:XFE2"))
        refuse(.sheet(name: "Data", cellRange: "A1:B2:C3"))
        refuse(.sheet(name: "Missing", cellRange: nil))
    }

    @Test("stale source, destination-is-source and non-workbook are refused")
    func sourceGuards() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source)
        let stale = String(repeating: "0", count: 64)

        #expect(throws: OfficePrintCopyError.staleSource) {
            _ = try OfficePrintCopy.prepare(
                sourceURL: source,
                destinationURL: root.appendingPathComponent("copy.xlsx"),
                expectedSHA256: stale,
                plan: OfficePDFPrintPlan(scope: .allVisibleSheets))
        }
        #expect(throws: OfficePrintCopyError.destinationIsSource) {
            _ = try OfficePrintCopy.prepare(
                sourceURL: source, destinationURL: source,
                expectedSHA256: nil,
                plan: OfficePDFPrintPlan(scope: .allVisibleSheets))
        }

        let docx = root.appendingPathComponent("word.docx")
        try Data("not really a docx".utf8).write(to: docx)
        #expect(throws: OfficePrintCopyError.unsupportedFormat("docx")) {
            _ = try OfficePrintCopy.prepare(
                sourceURL: docx,
                destinationURL: root.appendingPathComponent("copy.xlsx"),
                expectedSHA256: nil,
                plan: OfficePDFPrintPlan(scope: .documentSettings))
        }
    }

    @Test("a workbook with no visible sheet refuses a full-content scope")
    func noVisibleSheets() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("hidden-only.xlsx")
        // Build a one-sheet workbook through the shared builder, then mark
        // the only sheet hidden in a private copy of its workbook part.
        try OfficeDocumentBuilder.createWorkbook(at: source, sheets: [
            OfficeWorkbookSheet(name: "Only", rows: [["x"]]),
        ])
        let archive = try Archive(url: source, accessMode: .read)
        var members: [(String, Data)] = []
        for entry in archive where entry.type == .file {
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            if entry.path == "xl/workbook.xml" {
                var xml = String(decoding: data, as: UTF8.self)
                xml = xml.replacingOccurrences(of: "r:id=\"rId1\"",
                                               with: "r:id=\"rId1\" state=\"hidden\"")
                data = Data(xml.utf8)
            }
            members.append((entry.path, data))
        }
        try? FileManager.default.removeItem(at: source)
        let rebuilt = try Archive(url: source, accessMode: .create)
        for (path, data) in members {
            try rebuilt.addFloeEntry(path: path, data: data)
        }

        #expect(throws: OfficePrintCopyError.noVisibleSheets) {
            _ = try OfficePrintCopy.prepare(
                sourceURL: source,
                destinationURL: root.appendingPathComponent("copy.xlsx"),
                expectedSHA256: try FloeDigest.sha256Hex(ofFileAt: source),
                plan: OfficePDFPrintPlan(scope: .allVisibleSheets))
        }
    }

    // MARK: - Selected sheets (build 285 preview round)

    @Test("selected-sheets copy keeps exactly the chosen tabs printable")
    func selectedSheetsCopyKeepsExactlyTheChosenTabs() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source)
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let sourceBytes = try Data(contentsOf: source)
        let destination = root.appendingPathComponent("copy-selected.xlsx")

        let plan = OfficePDFPrintPlan(scope: .sheets(names: ["Data", "Summary"]))
        let copyPlan = try OfficePrintCopy.prepare(sourceURL: source,
                                                   destinationURL: destination,
                                                   expectedSHA256: sourceSHA,
                                                   plan: plan)
        // Printed names follow the workbook's own tab order, not the
        // request's spelling order.
        #expect(copyPlan.printedSheetNames == ["Summary", "Data"])
        #expect(copyPlan.suppressedSheetNames == ["Hidden"])
        #expect(copyPlan.printAreaReference == nil)
        #expect(copyPlan.preservedDocumentPrintArea == false)
        #expect(copyPlan.removedPrintAreas == 1)
        #expect(copyPlan.preservedPrintTitles == 1)
        #expect(copyPlan.madeTargetVisible == false)
        let reopened = try Archive(url: destination, accessMode: .read)
        let workbook = try xmlString(reopened, "xl/workbook.xml")
        // An explicitly chosen, already-visible tab stays printable: both
        // requested tabs are kept visible inside the copy, the active tab is
        // the first chosen tab in tab order, and the already-veryHidden tab
        // is untouched.
        #expect(workbook.contains("<sheet name=\"Summary\" sheetId=\"1\" r:id=\"rId1\"/>"))
        #expect(workbook.contains("<sheet name=\"Data\" sheetId=\"2\" r:id=\"rId2\"/>"))
        #expect(workbook.contains("state=\"veryHidden\""))
        #expect(workbook.contains("activeTab=\"0\""))
        #expect(!workbook.contains("'Data'!$B$2:$C$3"))
        #expect(workbook.contains("'Data'!$1:$1"))
        // Selection-scoped suppression coverage: choosing only one of the
        // two previously-visible tabs hides the other inside the copy only,
        // moves the active tab to the chosen one, and still leaves the
        // veryHidden tab untouched, print areas cleared and print titles kept.
        let onlyData = root.appendingPathComponent("copy-only-data.xlsx")
        let onlyCopy = try OfficePrintCopy.prepare(
            sourceURL: source, destinationURL: onlyData, expectedSHA256: sourceSHA,
            plan: OfficePDFPrintPlan(scope: .sheets(names: ["Data"])))
        #expect(onlyCopy.printedSheetNames == ["Data"])
        #expect(onlyCopy.suppressedSheetNames == ["Summary", "Hidden"])
        #expect(onlyCopy.printAreaReference == nil)
        #expect(onlyCopy.removedPrintAreas == 1)
        #expect(onlyCopy.preservedPrintTitles == 1)
        #expect(onlyCopy.madeTargetVisible == false)
        #expect(onlyCopy.setActiveTab == true)
        let onlyWorkbook = try xmlString(try Archive(url: onlyData, accessMode: .read),
                                         "xl/workbook.xml")
        #expect(onlyWorkbook.contains("<sheet name=\"Summary\" sheetId=\"1\" r:id=\"rId1\" state=\"hidden\"/>"))
        #expect(onlyWorkbook.contains("state=\"veryHidden\""))
        #expect(onlyWorkbook.contains("activeTab=\"1\""))
        #expect(!onlyWorkbook.contains("'Data'!$B$2:$C$3"))
        #expect(onlyWorkbook.contains("'Data'!$1:$1"))
        // The source is unchanged and the copy keeps the drawing/ink member
        // byte-for-byte (the full-content semantics the pagination fix needs).
        #expect(try Data(contentsOf: source) == sourceBytes)
        let archive = try Archive(url: source, accessMode: .read)
        #expect(try member(reopened, "xl/drawings/drawing1.xml")
                == member(archive, "xl/drawings/drawing1.xml"))
        #expect(try FloeDigest.sha256Hex(ofFileAt: source) == sourceSHA)
    }

    @Test("selected-sheets can resurrect an explicitly chosen hidden tab in the copy")
    func selectedSheetsCanIncludeHiddenTab() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source)
        let destination = root.appendingPathComponent("copy-hidden.xlsx")

        let plan = OfficePDFPrintPlan(scope: .sheets(names: ["Hidden"]))
        let copyPlan = try OfficePrintCopy.prepare(sourceURL: source,
                                                   destinationURL: destination,
                                                   expectedSHA256: nil,
                                                   plan: plan)
        #expect(copyPlan.printedSheetNames == ["Hidden"])
        #expect(copyPlan.suppressedSheetNames == ["Summary", "Data"])
        #expect(copyPlan.madeTargetVisible == true)
        #expect(copyPlan.setActiveTab == true)
        let workbook = try xmlString(try Archive(url: destination, accessMode: .read),
                                     "xl/workbook.xml")
        // The chosen veryHidden tab is visible inside the copy only; its
        // `state` member is gone there while the source stays untouched.
        #expect(workbook.contains("<sheet name=\"Hidden\" sheetId=\"3\" r:id=\"rId3\"/>"))
        #expect(!workbook.contains("veryHidden"))
        #expect(workbook.contains("activeTab=\"2\""))
    }

    @Test("selected-sheets refuses unknown, duplicate and empty selections without writing")
    func selectedSheetsRefusals() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source)
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)

        #expect(throws: OfficePDFPlanError.duplicateSheetName(name: "Data")) {
            try OfficePDFPrintPlan(scope: .sheets(names: ["Data", "Data"]))
                .validate(forExtension: "xlsx")
        }
        #expect(throws: OfficePDFPlanError.emptySheetSelection) {
            try OfficePDFPrintPlan(scope: .sheets(names: []))
                .validate(forExtension: "xlsx")
        }
        let unknownDestination = root.appendingPathComponent("refused-unknown.xlsx")
        #expect(throws: OfficePrintCopyError.unknownSheet(
            requested: "Missing", available: ["Summary", "Data", "Hidden"])) {
            _ = try OfficePrintCopy.prepare(sourceURL: source,
                                            destinationURL: unknownDestination,
                                            expectedSHA256: sourceSHA,
                                            plan: OfficePDFPrintPlan(scope: .sheets(names: ["Missing"])))
        }
        #expect(FileManager.default.fileExists(atPath: unknownDestination.path) == false)
    }

    // MARK: - Document print area scope

    @Test("print-area scope re-emits the target sheet's own saved area verbatim")
    func printAreaScopeKeepsSheetsOwnArea() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source)
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let destination = root.appendingPathComponent("copy-printarea.xlsx")

        let plan = OfficePDFPrintPlan(scope: .sheetWithPrintArea(name: "Data"))
        let copyPlan = try OfficePrintCopy.prepare(sourceURL: source,
                                                   destinationURL: destination,
                                                   expectedSHA256: sourceSHA,
                                                   plan: plan)
        #expect(copyPlan.printedSheetNames == ["Data"])
        #expect(copyPlan.printAreaReference == "'Data'!$B$2:$C$3")
        #expect(copyPlan.preservedDocumentPrintArea == true)
        let workbook = try xmlString(try Archive(url: destination, accessMode: .read),
                                     "xl/workbook.xml")
        #expect(workbook.contains("'Data'!$B$2:$C$3"))
        // Print titles stay for the document-print-area mode.
        #expect(workbook.contains("'Data'!$1:$1"))
        // Other tabs are suppressed inside the copy only.
        #expect(workbook.contains("<sheet name=\"Summary\" sheetId=\"1\" r:id=\"rId1\" state=\"hidden\"/>"))
        #expect(try FloeDigest.sha256Hex(ofFileAt: source) == sourceSHA)
    }

    @Test("print-area scope without its own area truthfully prints full content")
    func printAreaScopeFallsBackToFullContent() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source)
        let destination = root.appendingPathComponent("copy-printarea-none.xlsx")

        let plan = OfficePDFPrintPlan(scope: .sheetWithPrintArea(name: "Summary"))
        let copyPlan = try OfficePrintCopy.prepare(sourceURL: source,
                                                   destinationURL: destination,
                                                   expectedSHA256: nil,
                                                   plan: plan)
        // Summary declares no area: the copy declares none either (it never
        // adopts Data's area) and the sheet prints its full content.
        #expect(copyPlan.printAreaReference == nil)
        #expect(copyPlan.preservedDocumentPrintArea == false)
        let workbook = try xmlString(try Archive(url: destination, accessMode: .read),
                                     "xl/workbook.xml")
        #expect(!workbook.contains("'Data'!$B$2:$C$3"))
    }

    // MARK: - Exact scale and fit-pages

    @Test("exact scale writes fitToPage=0 plus scale and drops stale fit attributes")
    func exactScaleMembers() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source)
        let destination = root.appendingPathComponent("copy-scale.xlsx")

        let plan = OfficePDFPrintPlan(
            scope: .sheet(name: "Data", cellRange: "B2:C3"),
            pageSetup: OfficePDFPageSetup(scalePercent: 85))
        let copyPlan = try OfficePrintCopy.prepare(sourceURL: source,
                                                   destinationURL: destination,
                                                   expectedSHA256: nil,
                                                   plan: plan)
        let worksheet = try xmlString(try Archive(url: destination, accessMode: .read),
                                      "xl/worksheets/sheet2.xml")
        #expect(worksheet.contains("<pageSetUpPr fitToPage=\"0\"/>"))
        #expect(worksheet.contains("scale=\"85\""))
        #expect(!worksheet.contains("scale=\"100\""))
        #expect(!worksheet.contains("fitToWidth="))
        #expect(!worksheet.contains("fitToHeight="))
        #expect(copyPlan.appliedPageSetup.scalePercent == 85)
    }

    @Test("fit-to-pages writes both dimensions with fitToPage=1 and drops scale")
    func fitPagesMembers() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source)
        let destination = root.appendingPathComponent("copy-fitpages.xlsx")

        let plan = OfficePDFPrintPlan(
            scope: .sheet(name: "Data", cellRange: nil),
            pageSetup: OfficePDFPageSetup(fitPages: OfficePDFFitPages(width: 2, height: 3)))
        _ = try OfficePrintCopy.prepare(sourceURL: source,
                                        destinationURL: destination,
                                        expectedSHA256: nil,
                                        plan: plan)
        let worksheet = try xmlString(try Archive(url: destination, accessMode: .read),
                                      "xl/worksheets/sheet2.xml")
        #expect(worksheet.contains("<pageSetUpPr fitToPage=\"1\"/>"))
        #expect(worksheet.contains("fitToWidth=\"2\""))
        #expect(worksheet.contains("fitToHeight=\"3\""))
        #expect(!worksheet.contains("scale="))
    }

    @Test("scaling conflicts and out-of-range values are refused before any copy")
    func scalingRefusals() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source)

        #expect(throws: OfficePDFPlanError.conflictingScalingControls) {
            try OfficePDFPrintPlan(pageSetup: OfficePDFPageSetup(
                fit: .fitToOnePage, scalePercent: 85)).validate(forExtension: "xlsx")
        }
        #expect(throws: OfficePDFPlanError.conflictingScalingControls) {
            try OfficePDFPrintPlan(pageSetup: OfficePDFPageSetup(
                scalePercent: 85,
                fitPages: OfficePDFFitPages(width: 1, height: 1)))
                .validate(forExtension: "xlsx")
        }
        #expect(throws: OfficePDFPlanError.scalePercentOutOfRange(
            requested: 5, minimum: 10, maximum: 400)) {
            try OfficePDFPrintPlan(pageSetup: OfficePDFPageSetup(scalePercent: 5))
                .validate(forExtension: "xlsx")
        }
        #expect(throws: OfficePDFPlanError.fitPagesOutOfRange(
            requested: OfficePDFFitPages(width: 0, height: 1), maximum: 99)) {
            try OfficePDFPrintPlan(pageSetup: OfficePDFPageSetup(
                fitPages: OfficePDFFitPages(width: 0, height: 1)))
                .validate(forExtension: "xlsx")
        }
        let destination = root.appendingPathComponent("refused-scale.xlsx")
        #expect(throws: (any Error).self) {
            _ = try OfficePrintCopy.prepare(
                sourceURL: source, destinationURL: destination, expectedSHA256: nil,
                plan: OfficePDFPrintPlan(
                    scope: .sheet(name: "Data", cellRange: nil),
                    pageSetup: OfficePDFPageSetup(scalePercent: 401)))
        }
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }

    @Test("non-workbook formats refuse the new scopes and scaling controls")
    func newScopesRefuseNonWorkbookFormats() {
        #expect(throws: OfficePDFPlanError.unsupportedScope(format: "docx")) {
            try OfficePDFPrintPlan(scope: .sheets(names: ["A", "B"]))
                .validate(forExtension: "docx")
        }
        #expect(throws: OfficePDFPlanError.unsupportedScope(format: "ods")) {
            try OfficePDFPrintPlan(scope: .sheetWithPrintArea(name: "Sheet1"))
                .validate(forExtension: "ods")
        }
        #expect(throws: OfficePDFPlanError.unsupportedPageSetup(format: "pptx")) {
            try OfficePDFPrintPlan(pageSetup: OfficePDFPageSetup(scalePercent: 100))
                .validate(forExtension: "pptx")
        }
    }

    @Test("the extended plan contract round-trips through Codable")
    func extendedPlanCodableRoundTrip() throws {
        let plans = [
            OfficePDFPrintPlan(scope: .sheets(names: ["Data", "It''s Tab"])),
            OfficePDFPrintPlan(scope: .sheetWithPrintArea(name: "Data")),
            OfficePDFPrintPlan(scope: .sheet(name: "Data", cellRange: nil),
                               pageSetup: OfficePDFPageSetup(scalePercent: 60)),
            OfficePDFPrintPlan(scope: .allVisibleSheets,
                               pageSetup: OfficePDFPageSetup(
                                   fitPages: OfficePDFFitPages(width: 2, height: 3))),
            OfficePDFPrintPlan(pageSetup: OfficePDFPageSetup(printGridlines: true)),
            OfficePDFPrintPlan(scope: .sheets(names: ["Data"]),
                               pageSetup: OfficePDFPageSetup(scalePercent: 120,
                                                             printGridlines: false)),
        ]
        let roundTrip = try JSONEncoder().encode(plans)
        let decoded = try JSONDecoder().decode([OfficePDFPrintPlan].self, from: roundTrip)
        #expect(decoded == plans)
    }

    // MARK: - Printed gridlines (Excel print usability)

    @Test("explicit gridlines on keeps the other saved print flags, propagates the scale and leaves the source and borders untouched")
    func gridlinesOnPreservesOtherFlagsAndSource() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source,
                         dataPrintOptions: #"<printOptions headings="1" gridLines="0" horizontalCentered="1"/>"#)
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let sourceStyles = try member(try Archive(url: source, accessMode: .read), "xl/styles.xml")
        let destination = root.appendingPathComponent("copy-grid-on.xlsx")

        let plan = OfficePDFPrintPlan(
            scope: .sheet(name: "Data", cellRange: nil),
            pageSetup: OfficePDFPageSetup(scalePercent: 85, printGridlines: true))
        let copyPlan = try OfficePrintCopy.prepare(sourceURL: source,
                                                   destinationURL: destination,
                                                   expectedSHA256: sourceSHA,
                                                   plan: plan)
        let copy = try Archive(url: destination, accessMode: .read)
        let worksheet = try xmlString(copy, "xl/worksheets/sheet2.xml")
        #expect(worksheet.contains(#"gridLines="1""#))
        // The other members the saved worksheet declared survive verbatim
        // next to the gridlines change.
        #expect(worksheet.contains(#"headings="1""#))
        #expect(worksheet.contains(#"horizontalCentered="1""#))
        // The percentage propagates through the same verified copy.
        #expect(worksheet.contains(#"scale="85""#))
        #expect(copyPlan.appliedPageSetup.printGridlines == true)
        #expect(copyPlan.appliedPageSetup.scalePercent == 85)
        // Cell borders live in styles.xml; the copy must keep them byte-
        // identical, and the source package itself never changes.
        #expect(try member(copy, "xl/styles.xml") == sourceStyles)
        #expect(try FloeDigest.sha256Hex(ofFileAt: source) == sourceSHA)
    }

    @Test("gridlines on coerces a saved gridLinesSet false because ECMA-376 prints only when both members are true")
    func gridlinesOnCoercesSavedGridLinesSet() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source,
                         dataPrintOptions: #"<printOptions headings="1" gridLines="0" gridLinesSet="false"/>"#)
        let destination = root.appendingPathComponent("copy-grid-coerce.xlsx")

        let plan = OfficePDFPrintPlan(
            scope: .sheet(name: "Data", cellRange: nil),
            pageSetup: OfficePDFPageSetup(printGridlines: true))
        _ = try OfficePrintCopy.prepare(sourceURL: source,
                                        destinationURL: destination,
                                        expectedSHA256: nil,
                                        plan: plan)
        let worksheet = try xmlString(try Archive(url: destination, accessMode: .read),
                                      "xl/worksheets/sheet2.xml")
        #expect(worksheet.contains(#"gridLines="1""#))
        #expect(worksheet.contains(#"gridLinesSet="1""#))
        #expect(!worksheet.contains("gridLinesSet=\"false\""))
        #expect(worksheet.contains(#"headings="1""#))
    }

    @Test("gridlines off writes only gridLines=0 and leaves the other saved members alone")
    func gridlinesOffWritesOnlyGridLinesZero() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source,
                         dataPrintOptions: #"<printOptions headings="1" gridLines="true" gridLinesSet="true"/>"#)
        let destination = root.appendingPathComponent("copy-grid-off.xlsx")

        let plan = OfficePDFPrintPlan(
            scope: .sheet(name: "Data", cellRange: nil),
            pageSetup: OfficePDFPageSetup(printGridlines: false))
        _ = try OfficePrintCopy.prepare(sourceURL: source,
                                        destinationURL: destination,
                                        expectedSHA256: nil,
                                        plan: plan)
        let worksheet = try xmlString(try Archive(url: destination, accessMode: .read),
                                      "xl/worksheets/sheet2.xml")
        #expect(worksheet.contains(#"gridLines="0""#))
        // An explicit "off" is complete with gridLines=0; gridLinesSet keeps
        // the saved spelling and every other flag survives.
        #expect(worksheet.contains(#"gridLinesSet="true""#))
        #expect(worksheet.contains(#"headings="1""#))
    }

    @Test("a created printOptions element lands before pageMargins in schema order")
    func gridlinesCreatedInSchemaOrder() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source)
        let destination = root.appendingPathComponent("copy-grid-create.xlsx")

        let plan = OfficePDFPrintPlan(
            scope: .documentSettings,
            pageSetup: OfficePDFPageSetup(printGridlines: true))
        #expect(plan.requiresPrintCopy)
        let copyPlan = try OfficePrintCopy.prepare(sourceURL: source,
                                                   destinationURL: destination,
                                                   expectedSHA256: nil,
                                                   plan: plan)
        #expect(copyPlan.changedSheetParts.count == 2)
        let copy = try Archive(url: destination, accessMode: .read)
        let worksheet = try xmlString(copy, "xl/worksheets/sheet2.xml")
        #expect(worksheet.contains(#"<printOptions gridLines="1" gridLinesSet="1"/>"#))
        guard let options = worksheet.range(of: "<printOptions"),
              let margins = worksheet.range(of: "<pageMargins"),
              let setup = worksheet.range(of: "<pageSetup") else {
            Issue.record("printOptions must exist before pageMargins/pageSetup")
            return
        }
        #expect(options.lowerBound < margins.lowerBound)
        #expect(margins.lowerBound < setup.lowerBound)
        // A sheet without any page members gets the element too (before the
        // closing root), and the very-hidden sheet is never rewritten.
        let summary = try xmlString(copy, "xl/worksheets/sheet1.xml")
        #expect(summary.contains(#"<printOptions gridLines="1" gridLinesSet="1"/>"#))
        let hidden = try xmlString(copy, "xl/worksheets/sheet3.xml")
        #expect(!hidden.contains("printOptions"))
    }

    @Test("off creates a self-contained gridLines=0 element without touching gridLinesSet")
    func gridlinesOffCreatedElement() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source)
        let destination = root.appendingPathComponent("copy-grid-off-create.xlsx")

        let plan = OfficePDFPrintPlan(
            scope: .sheet(name: "Data", cellRange: nil),
            pageSetup: OfficePDFPageSetup(printGridlines: false))
        _ = try OfficePrintCopy.prepare(sourceURL: source,
                                        destinationURL: destination,
                                        expectedSHA256: nil,
                                        plan: plan)
        let worksheet = try xmlString(try Archive(url: destination, accessMode: .read),
                                      "xl/worksheets/sheet2.xml")
        #expect(worksheet.contains(#"<printOptions gridLines="0"/>"#))
        #expect(!worksheet.contains("gridLinesSet"))
    }

    @Test("the default choice keeps the worksheet's own printOptions byte-identical")
    func nilChoiceKeepsPrintOptionsIdentical() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        let saved = #"<printOptions headings="1" gridLines="1" gridLinesSet="0"/>"#
        try makeWorkbook(at: source, dataPrintOptions: saved)
        let destination = root.appendingPathComponent("copy-grid-keep.xlsx")

        // Only the paper changes; the gridlines decision stays unmade.
        let plan = OfficePDFPrintPlan(
            scope: .sheet(name: "Data", cellRange: nil),
            pageSetup: OfficePDFPageSetup(paper: .a3))
        let copyPlan = try OfficePrintCopy.prepare(sourceURL: source,
                                                   destinationURL: destination,
                                                   expectedSHA256: nil,
                                                   plan: plan)
        #expect(copyPlan.appliedPageSetup.printGridlines == nil)
        let worksheet = try xmlString(try Archive(url: destination, accessMode: .read),
                                      "xl/worksheets/sheet2.xml")
        #expect(worksheet.contains(saved))
        #expect(!worksheet.contains(#"gridLines="0""#))

        // The fully default setup is still "no worksheet change at all".
        #expect(OfficePDFPageSetup().isDocumentSettings)
        #expect(OfficePDFPageSetup(printGridlines: true).hasOverrides)
    }

    @Test("gridlines choices validate honestly per format")
    func gridlinesFormatValidation() throws {
        let on = OfficePDFPrintPlan(pageSetup: OfficePDFPageSetup(printGridlines: true))
        #expect(on.pageSetup.hasOverrides)
        #expect(on.requiresPrintCopy)
        try on.validate(forExtension: "xlsx")
        #expect(throws: OfficePDFPlanError.unsupportedPageSetup(format: "docx")) {
            try on.validate(forExtension: "docx")
        }
        #expect(throws: OfficePDFPlanError.unsupportedPageSetup(format: "pptx")) {
            try on.validate(forExtension: "pptx")
        }
        #expect(throws: OfficePDFPlanError.unsupportedPageSetup(format: "ods")) {
            try OfficePDFPrintPlan(pageSetup: OfficePDFPageSetup(printGridlines: false))
                .validate(forExtension: "ods")
        }
        // The default choice keeps document-settings passthrough.
        try OfficePDFPrintPlan(pageSetup: OfficePDFPageSetup(printGridlines: nil))
            .validate(forExtension: "docx")
    }

    // MARK: - Plan / page range

    @Test("page range parse is strict and normalizes order and duplicates")
    func pageRangeParse() throws {
        #expect(OfficePDFPageRange.parse("3,1-2")?.pages == [1, 2, 3])
        #expect(OfficePDFPageRange.parse(" 1 - 3 , 5 ")?.pages == [1, 2, 3, 5])
        #expect(OfficePDFPageRange.parse("")?.pages == [])
        #expect(OfficePDFPageRange.parse("0") == nil)
        #expect(OfficePDFPageRange.parse("3-1") == nil)
        #expect(OfficePDFPageRange.parse("1,,2") == nil)
        #expect(OfficePDFPageRange.parse("1-501") == nil)
        #expect(OfficePDFPageRange.parse("abc") == nil)

        #expect(try OfficePDFPageRange(pages: [4, 2, 4]).validated(pageCount: 5) == [2, 4])
        #expect(try OfficePDFPageRange(pages: []).validated(pageCount: 3) == [1, 2, 3])
        #expect(throws: OfficePDFPlanError.pageOutOfRange(page: 9, pageCount: 5)) {
            _ = try OfficePDFPageRange(pages: [9]).validated(pageCount: 5)
        }
        #expect(throws: OfficePDFPlanError.invalidPageSelection(
            reason: "PDF page numbers start at 1")) {
            _ = try OfficePDFPageRange(pages: [0]).validated(pageCount: 5)
        }
        let tooMany = Array(1...501)
        #expect(throws: OfficePDFPlanError.tooManySelectedPages(
            requested: 501, maximum: OfficePDFPageRange.maximumSelectedPages)) {
            _ = try OfficePDFPageRange(pages: tooMany).validated(pageCount: 1000)
        }
    }

    @Test("format support keeps legacy formats on the live-finalize path")
    func formatSupport() throws {
        #expect(OfficePDFFormatSupport.resolve(forExtension: "XLSX") == .workbook)
        #expect(OfficePDFFormatSupport.resolve(forExtension: "docx") == .paginated)
        #expect(OfficePDFFormatSupport.resolve(forExtension: "pptx") == .paginated)
        for ext in ["xls", "ods", "doc", "odt", "rtf", "ppt", "odp"] {
            let support = try #require(OfficePDFFormatSupport.resolve(forExtension: ext))
            #expect(support == .documentSettingsOnly)
            #expect(!support.supportsSavedIsolatedExport)
            #expect(support.supportsFinalPageRange)
        }
        #expect(OfficePDFFormatSupport.resolve(forExtension: "pdf") == nil)

        try OfficePDFPrintPlan(
            scope: .documentSettings,
            pageRange: OfficePDFPageRange(pages: [2, 3])
        ).validate(forExtension: "ods")
        #expect(throws: OfficePDFPlanError.unsupportedScope(format: "ods")) {
            try OfficePDFPrintPlan(scope: .sheet(name: "Sheet1", cellRange: nil))
                .validate(forExtension: "ods")
        }
        #expect(throws: OfficePDFPlanError.unsupportedPageSetup(format: "odt")) {
            try OfficePDFPrintPlan(pageSetup: OfficePDFPageSetup(paper: .a4))
                .validate(forExtension: "odt")
        }
    }

    @Test("document-settings page setup applies only to visible sheets")
    func documentSettingsPageSetupVisibleOnly() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.xlsx")
        try makeWorkbook(at: source)
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let destination = root.appendingPathComponent("copy.xlsx")

        let plan = OfficePDFPrintPlan(
            scope: .documentSettings,
            pageSetup: OfficePDFPageSetup(paper: .a3, fit: .fitToOnePage))
        let copyPlan = try OfficePrintCopy.prepare(sourceURL: source,
                                                   destinationURL: destination,
                                                   expectedSHA256: sourceSHA,
                                                   plan: plan)
        #expect(copyPlan.changedSheetParts.count == 2)
        #expect(copyPlan.changedSheetParts.contains("xl/worksheets/sheet1.xml"))
        #expect(copyPlan.changedSheetParts.contains("xl/worksheets/sheet2.xml"))
        #expect(!copyPlan.changedSheetParts.contains("xl/worksheets/sheet3.xml"))
        #expect(copyPlan.preservedPrintAreas == 1)
        #expect(copyPlan.preservedPrintTitles == 1)

        let copy = try Archive(url: destination, accessMode: .read)
        let visible = try xmlString(copy, "xl/worksheets/sheet1.xml")
        #expect(visible.contains("paperSize=\"8\""))
        #expect(visible.contains("fitToPage=\"1\""))
        let hidden = try xmlString(copy, "xl/worksheets/sheet3.xml")
        #expect(!hidden.contains("paperSize="))
        #expect(!hidden.contains("fitToPage="))
        let workbook = try xmlString(copy, "xl/workbook.xml")
        #expect(workbook.contains("_xlnm.Print_Area"))
        #expect(workbook.contains("_xlnm.Print_Titles"))
    }

    @Test("non-workbook custom scopes are refused explicitly")
    func nonWorkbookPlanValidation() throws {
        let plan = OfficePDFPrintPlan(scope: .sheet(name: "Sheet1", cellRange: nil))
        #expect(throws: OfficePDFPlanError.unsupportedScope(format: "docx")) {
            try plan.validate(for: .docx)
        }
        let setup = OfficePDFPrintPlan(pageSetup: OfficePDFPageSetup(paper: .a4))
        #expect(throws: OfficePDFPlanError.unsupportedPageSetup(format: "pptx")) {
            try setup.validate(for: .pptx)
        }
        try OfficePDFPrintPlan().validate(for: .docx)
        try OfficePDFPrintPlan().validate(for: .xlsx)
    }

    // MARK: - Helpers

    /// Ordered `visible|hidden|veryHidden` states from a workbook part.
    private func sheetStates(in workbook: String) -> [String] {
        var states: [String] = []
        var search = workbook.startIndex
        while let open = workbook.range(of: "<sheet ", range: search..<workbook.endIndex) {
            guard let end = workbook.range(of: ">", range: open.upperBound..<workbook.endIndex) else { break }
            let element = String(workbook[open.lowerBound..<end.upperBound])
            if let state = element.range(of: "state=\"") {
                let valueStart = state.upperBound
                if let valueEnd = element.range(of: "\"", range: valueStart..<element.endIndex) {
                    states.append(String(element[valueStart..<valueEnd.lowerBound]))
                } else {
                    states.append("visible")
                }
            } else {
                states.append("visible")
            }
            search = end.upperBound
        }
        return states
    }
}

private extension OfficePDFPlanError {
    /// A stable value for the unknown-sheet case where the available list is
    /// fixture-defined.
    static var englishUnknownSheet: OfficePDFPlanError {
        .unknownSheet(requested: "Missing", available: ["Summary", "Data", "Hidden"])
    }
}
