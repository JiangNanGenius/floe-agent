import Foundation
import Testing
import ZIPFoundation
import FloeCore
import FloeTools
@testable import FloeDocuments

// MARK: - Dispatch plans mirror the pinned bundle

@Suite("Office engine command catalog")
struct OfficeEngineCommandCatalogTests {
    @Test("Word plans use the pinned engine command encodings")
    func wordPlans() throws {
        #expect(OfficeEngineCommand.wordStyle(name: "Heading 2").plan.steps == [
            .uno(name: ".uno:StyleApply", arguments: [
                "Style": .string("Heading 2"),
                "FamilyName": .string("ParagraphStyles"),
            ]),
        ])
        #expect(OfficeEngineCommand.wordBulletList.plan.steps == [.uno(name: ".uno:DefaultBullet", arguments: [:])])
        #expect(OfficeEngineCommand.wordNumberedList.plan.steps == [.uno(name: ".uno:DefaultNumbering", arguments: [:])])
        #expect(OfficeEngineCommand.wordAlignment(.justified).plan.steps == [.uno(name: ".uno:JustifyPara", arguments: [:])])
        #expect(OfficeEngineCommand.wordAlignment(.center).plan.steps == [.uno(name: ".uno:CenterPara", arguments: [:])])
        #expect(OfficeEngineCommand.wordInsertTable(rows: 3, columns: 4).plan.steps == [
            .uno(name: ".uno:InsertTable", arguments: ["Columns": .long(4), "Rows": .long(3)]),
        ])
    }

    @Test("Excel plans target an explicit cell before selection-relative commands")
    func excelPlans() throws {
        #expect(OfficeEngineCommand.excelNumberFormat(.percent, cell: "B2").plan.steps == [
            .uno(name: ".uno:GoToCell", arguments: ["ToPoint": .string("B2")]),
            .uno(name: ".uno:NumberFormatPercent", arguments: [:]),
        ])
        let insert = OfficeEngineCommand.excelInsertRows(count: 2, at: "A5").plan.steps
        #expect(insert.first == .uno(name: ".uno:GoToCell", arguments: ["ToPoint": .string("A5")]))
        #expect(insert.count == 3)
        #expect(insert[1] == .uno(name: ".uno:InsertRowsBefore", arguments: [:]))
        #expect(OfficeEngineCommand.excelFreezePanes(at: "B2").plan.steps == [
            .uno(name: ".uno:GoToCell", arguments: ["ToPoint": .string("B2")]),
            .uno(name: ".uno:FreezePanes", arguments: [:]),
        ])
        #expect(OfficeEngineCommand.excelSort(ascending: false, range: "A1:C9").plan.steps == [
            .uno(name: ".uno:GoToCell", arguments: ["ToPoint": .string("A1:C9")]),
            .uno(name: ".uno:SortDescending", arguments: [:]),
        ])
        #expect(OfficeEngineCommand.excelAutoFilter.plan.steps == [.uno(name: ".uno:DataFilterAutoFilter", arguments: [:])])
    }

    @Test("Presentation plans use the pinned duplicate/reorder/align commands")
    func presentationPlans() throws {
        #expect(OfficeEngineCommand.pptDuplicateSlide(at: 3).plan.steps == [
            .socket(payload: "uno .uno:DuplicatePage {\"InsertPos\":{\"type\":\"int16\",\"value\":2}}"),
        ])
        #expect(OfficeEngineCommand.pptMoveSlide(from: 1, to: 4).plan.steps == [
            .socket(payload: "uno .uno:DuplicatePage {\"InsertPos\":{\"type\":\"int16\",\"value\":3}}"),
            .selectPart(0),
            .uno(name: ".uno:DeletePage", arguments: [:]),
        ])
        // The pinned object-align menu: ObjectAlignLeft / AlignCenter /
        // ObjectAlignRight / AlignUp / AlignMiddle / AlignDown.
        #expect(OfficeEngineCommand.pptAlignObjects(.left).plan.steps == [.uno(name: ".uno:ObjectAlignLeft", arguments: [:])])
        #expect(OfficeEngineCommand.pptAlignObjects(.center).plan.steps == [.uno(name: ".uno:AlignCenter", arguments: [:])])
        #expect(OfficeEngineCommand.pptAlignObjects(.right).plan.steps == [.uno(name: ".uno:ObjectAlignRight", arguments: [:])])
        #expect(OfficeEngineCommand.pptAlignObjects(.top).plan.steps == [.uno(name: ".uno:AlignUp", arguments: [:])])
        #expect(OfficeEngineCommand.pptAlignObjects(.middle).plan.steps == [.uno(name: ".uno:AlignMiddle", arguments: [:])])
        #expect(OfficeEngineCommand.pptAlignObjects(.bottom).plan.steps == [.uno(name: ".uno:AlignDown", arguments: [:])])
    }

    @Test("validation fails closed on out-of-range or malformed arguments")
    func validation() throws {
        #expect(throws: (any Error).self) { try OfficeEngineCommand.wordStyle(name: "Fancy").validate() }
        #expect(throws: (any Error).self) { try OfficeEngineCommand.wordInsertTable(rows: 0, columns: 2).validate() }
        #expect(throws: (any Error).self) { try OfficeEngineCommand.wordInsertTable(rows: 101, columns: 2).validate() }
        #expect(throws: (any Error).self) { try OfficeEngineCommand.excelInsertRows(count: 0, at: "A1").validate() }
        #expect(throws: (any Error).self) { try OfficeEngineCommand.excelInsertRows(count: 1, at: "1A").validate() }
        #expect(throws: (any Error).self) { try OfficeEngineCommand.excelNumberFormat(.decimal, cell: "A0").validate() }
        #expect(throws: (any Error).self) { try OfficeEngineCommand.excelSort(ascending: true, range: "A1").validate() }
        #expect(throws: (any Error).self) { try OfficeEngineCommand.pptMoveSlide(from: 2, to: 2).validate() }
        try OfficeEngineCommand.excelNumberFormat(.percent, cell: "B2").validate()
    }

    @Test("the codec round-trips every catalog command and rejects unknown ids")
    func codec() throws {
        for format in OfficeDocumentFormat.allCases {
            for command in OfficeEngineCommandCatalog.engineCommands(format) {
                let json = try OfficeCommandCodec.encode([command])
                let decoded = try OfficeCommandCodec.decode(json)
                #expect(decoded == [command], "round trip failed for \(command.id)")
                try command.validate()
            }
        }
        #expect(throws: (any Error).self) {
            _ = try OfficeCommandCodec.decode(#"[{"id":"word.explode","arguments":{}}]"#)
        }
        #expect(throws: (any Error).self) {
            _ = try OfficeCommandCodec.decode(#"[{"id":"excel.numberFormat","arguments":{"format":"percent"}}]"#)
        }
    }

    @Test("selection-relative commands are marked for fingerprint binding")
    func selectionRequirements() {
        let required: Set<String> = ["word.style", "word.bulletList", "word.numberedList",
                                     "word.alignment", "excel.sort", "excel.autoFilter",
                                     "pptx.alignObjects"]
        for format in OfficeDocumentFormat.allCases {
            for command in OfficeEngineCommandCatalog.engineCommands(format) {
                #expect(command.requiresSelectionFingerprint == required.contains(command.id),
                        "\(command.id) selection requirement")
                #expect(!command.targetSummary.isEmpty)
            }
        }
    }

    @Test("grant store is single use with reservation release")
    func grantStore() async throws {
        let store = OfficeProposalGrantStore(timeToLive: 300, idProvider: { "grant-1" })
        let proposal = OfficeCommandProposal(documentID: "a.docx", format: "docx",
                                             baseSHA256: String(repeating: "a", count: 64),
                                             summary: "s", commandsJSON: "[]", expectations: [])
        let grant = await store.issueGrant(proposal: proposal)
        #expect(await store.reserve(grantID: grant, proposalID: proposal.id,
                                    documentID: proposal.documentID,
                                    sha256: proposal.baseSHA256) == .reserved)
        #expect(await store.reserve(grantID: grant, proposalID: proposal.id,
                                    documentID: proposal.documentID,
                                    sha256: proposal.baseSHA256) == .alreadyReserved)
        await store.releaseReservation(grantID: grant)
        #expect(await store.consume(grantID: grant, proposalID: proposal.id,
                                    documentID: proposal.documentID,
                                    sha256: proposal.baseSHA256) == .authorized)
        #expect(await store.consume(grantID: grant, proposalID: proposal.id,
                                    documentID: proposal.documentID,
                                    sha256: proposal.baseSHA256) == .alreadyConsumed)
        #expect(await store.consume(grantID: "missing", proposalID: proposal.id,
                                    documentID: proposal.documentID,
                                    sha256: proposal.baseSHA256) == .unknownGrant)
    }
}

// MARK: - Target-aware saved-package verification

@Suite("Office saved-package verification")
struct OfficeOutputValidationTests {
    private func temporaryURL(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-office-validation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(name)
    }

    private func writePackage(_ url: URL, entries: [String: String]) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (path, value) in entries {
            try archive.addFloeEntry(path: path, data: Data(value.utf8))
        }
    }

    private func wordPackage(paragraphs: String, styles: String,
                             numbering: String? = nil, tables: String = "") throws -> URL {
        let url = try temporaryURL("document.docx")
        var entries = [
            "[Content_Types].xml": #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>"#,
            "word/document.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
            \(paragraphs)\(tables)
            </w:body></w:document>
            """,
            "word/styles.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\(styles)</w:styles>
            """,
        ]
        if let numbering { entries["word/numbering.xml"] = numbering }
        try writePackage(url, entries: entries)
        return url
    }

    private func workbookPackage(styles: String, sheet: String) throws -> URL {
        let url = try temporaryURL("workbook.xlsx")
        try writePackage(url, entries: [
            "[Content_Types].xml": #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>"#,
            "xl/workbook.xml": #"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"/></sheets></workbook>"#,
            "xl/styles.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\(styles)</styleSheet>
            """,
            "xl/worksheets/sheet1.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\(sheet)</sheetData></worksheet>
            """,
        ])
        return url
    }

    @Test("Word style verification is a target-aware delta")
    func wordStyleDelta() throws {
        let plain = #"<w:p><w:r><w:t>Alpha</w:t></w:r></w:p>"#
        let heading = #"<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Alpha</w:t></w:r></w:p>"#
        let normalOther = #"<w:p><w:r><w:t>Beta</w:t></w:r></w:p>"#
        let styles = #"<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/></w:style>"#

        let before = try OfficeOutputSnapshot.capture(url: try wordPackage(paragraphs: plain + normalOther, styles: styles))
        let applied = try OfficeOutputSnapshot.capture(url: try wordPackage(paragraphs: heading + normalOther, styles: styles))
        try OfficeOutputValidator.verify(before: before, after: applied,
                                         expectations: [.wordParagraphStyle(styleName: "Heading 1")])

        // Wrong-target no-op: the paragraph already had the style and nothing
        // changed — a global "some paragraph has Heading 1" check would pass,
        // the delta check must fail.
        let alreadyStyled = try OfficeOutputSnapshot.capture(url: try wordPackage(paragraphs: heading + normalOther, styles: styles))
        #expect(throws: OfficeOutputValidationError.self) {
            try OfficeOutputValidator.verify(before: alreadyStyled,
                                             after: alreadyStyled,
                                             expectations: [.wordParagraphStyle(styleName: "Heading 1")])
        }
        // Applying the style to a DIFFERENT paragraph still counts as a delta.
        let otherStyled = try OfficeOutputSnapshot.capture(url: try wordPackage(
            paragraphs: plain + heading.replacingOccurrences(of: "Alpha", with: "Beta"), styles: styles))
        try OfficeOutputValidator.verify(before: before, after: otherStyled,
                                         expectations: [.wordParagraphStyle(styleName: "Heading 1")])
    }

    @Test("Word alignment, list and table verification are deltas")
    func wordAlignmentListTable() throws {
        let plain = #"<w:p><w:r><w:t>Alpha</w:t></w:r></w:p>"#
        let centered = #"<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:t>Alpha</w:t></w:r></w:p>"#
        let styles = #"<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/></w:style>"#
        let before = try OfficeOutputSnapshot.capture(url: try wordPackage(paragraphs: plain, styles: styles))
        let after = try OfficeOutputSnapshot.capture(url: try wordPackage(paragraphs: centered, styles: styles))
        try OfficeOutputValidator.verify(before: before, after: after, expectations: [.wordAlignment("center")])
        #expect(throws: OfficeOutputValidationError.self) {
            try OfficeOutputValidator.verify(before: before, after: before, expectations: [.wordAlignment("center")])
        }

        // Bulleted list: numbering.xml must declare a bullet, and a paragraph
        // must gain numPr.
        let bulleted = #"<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>Alpha</w:t></w:r></w:p>"#
        let numbering = #"<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl></w:abstractNum></w:numbering>"#
        let listBefore = try OfficeOutputSnapshot.capture(url: try wordPackage(paragraphs: plain, styles: styles, numbering: numbering))
        let listAfter = try OfficeOutputSnapshot.capture(url: try wordPackage(paragraphs: bulleted, styles: styles, numbering: numbering))
        try OfficeOutputValidator.verify(before: listBefore, after: listAfter, expectations: [.wordList(ordered: false)])
        #expect(throws: OfficeOutputValidationError.self) {
            try OfficeOutputValidator.verify(before: listBefore, after: listBefore, expectations: [.wordList(ordered: false)])
        }

        // Table: one NEW table must appear.
        let empty = try OfficeOutputSnapshot.capture(url: try wordPackage(paragraphs: plain, styles: styles))
        let table = #"<w:tbl><w:tr><w:tc><w:p><w:r><w:t>a</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>b</w:t></w:r></w:p></w:tc></w:tr></w:tbl>"#
        let withTable = try OfficeOutputSnapshot.capture(url: try wordPackage(paragraphs: plain, styles: styles, tables: table))
        try OfficeOutputValidator.verify(before: empty, after: withTable,
                                         expectations: [.wordTableShape(rows: 1, columns: 2)])
        #expect(throws: OfficeOutputValidationError.self) {
            try OfficeOutputValidator.verify(before: withTable, after: withTable,
                                             expectations: [.wordTableShape(rows: 1, columns: 2)])
        }
    }

    @Test("Excel number format verifies the addressed cell, not any cell")
    func excelCellFormat() throws {
        let styles = #"<numFmts count="1"><numFmt numFmtId="164" formatCode="0.00%"/></numFmts><cellXfs count="2"><xf numFmtId="0"/><xf numFmtId="164"/></cellXfs>"#
        let plainSheet = #"<row r="1"><c r="A1"><v>1</v></c></row><row r="2"><c r="B2"><v>0.5</v></c></row>"#
        let percentSheet = #"<row r="1"><c r="A1"><v>1</v></c></row><row r="2"><c r="B2" s="1"><v>0.5</v></c></row>"#
        let before = try OfficeOutputSnapshot.capture(url: try workbookPackage(styles: styles, sheet: plainSheet))
        let after = try OfficeOutputSnapshot.capture(url: try workbookPackage(styles: styles, sheet: percentSheet))
        try OfficeOutputValidator.verify(before: before, after: after,
                                         expectations: [.excelNumberFormat(.percent, cell: "B2")])

        // Wrong target: A1 is unchanged; a global "a percent format exists"
        // check would pass, the addressed-cell delta must fail.
        #expect(throws: OfficeOutputValidationError.self) {
            try OfficeOutputValidator.verify(before: before, after: after,
                                             expectations: [.excelNumberFormat(.percent, cell: "A1")])
        }
        // No-op: B2 already had the percent format.
        #expect(throws: OfficeOutputValidationError.self) {
            try OfficeOutputValidator.verify(before: after, after: after,
                                             expectations: [.excelNumberFormat(.percent, cell: "B2")])
        }
    }

    @Test("Excel rows and freeze panes verify the addressed target")
    func excelRowsAndFreeze() throws {
        let styles = #"<cellXfs count="1"><xf numFmtId="0"/></cellXfs>"#
        let oneRow = #"<row r="1"><c r="A1"><v>1</v></c></row>"#
        let threeRows = oneRow + #"<row r="2"><c r="A2"><v>2</v></c></row><row r="3"><c r="A3"><v>3</v></c></row>"#
        let before = try OfficeOutputSnapshot.capture(url: try workbookPackage(styles: styles, sheet: oneRow))
        let after = try OfficeOutputSnapshot.capture(url: try workbookPackage(styles: styles, sheet: threeRows))
        try OfficeOutputValidator.verify(before: before, after: after, expectations: [.excelRowDelta(2)])
        #expect(throws: OfficeOutputValidationError.self) {
            try OfficeOutputValidator.verify(before: before, after: before, expectations: [.excelRowDelta(2)])
        }

        let frozen = try OfficeOutputSnapshot.capture(url: try workbookPackage(
            styles: styles,
            sheet: #"<row r="1"><c r="A1"><v>1</v></c></row>"#))
        // sheet XML needs the pane element: rebuild with it.
        let frozenURL = try temporaryURL("frozen.xlsx")
        try writePackage(frozenURL, entries: [
            "[Content_Types].xml": #"<Types/>"#,
            "xl/styles.xml": #"<styleSheet>\(styles)</styleSheet>"#,
            "xl/worksheets/sheet1.xml": #"<worksheet><sheetViews><sheetView><pane xSplit="1" ySplit="1" topLeftCell="B2" activePane="bottomRight" state="frozen"/></sheetView></sheetViews><sheetData><row r="1"><c r="A1"><v>1</v></c></row></sheetData></worksheet>"#,
        ])
        let withPane = try OfficeOutputSnapshot.capture(url: frozenURL)
        try OfficeOutputValidator.verify(before: frozen, after: withPane,
                                         expectations: [.excelFreezePane(cell: "B2")])
        #expect(throws: OfficeOutputValidationError.self) {
            try OfficeOutputValidator.verify(before: frozen, after: withPane,
                                             expectations: [.excelFreezePane(cell: "C3")])
        }
    }

    @Test("formula error cells are located from the saved package")
    func errorCells() throws {
        let styles = #"<cellXfs count="1"><xf numFmtId="0"/></cellXfs>"#
        let sheet = #"<row r="1"><c r="A1"><v>1</v></c><c r="B1" t="e"><v>#DIV/0!</v></c></row><row r="2"><c r="A2"><f>1/0</f><v>#DIV/0!</v></c></row>"#
        let snapshot = try OfficeOutputSnapshot.capture(url: try workbookPackage(styles: styles, sheet: sheet))
        #expect(snapshot.errorCells.contains(OfficeErrorCell(cell: "B1", error: "#DIV/0!")))
        try OfficeOutputValidator.verify(before: nil, after: snapshot, expectations: [.excelErrorCells(atLeast: 1)])
    }

    @Test("slide order verification uses the saved presentation order")
    func slideOrder() throws {
        let url = try temporaryURL("deck.pptx")
        try writePackage(url, entries: [
            "[Content_Types].xml": #"<Types/>"#,
            "ppt/presentation.xml": #"<p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:sldIdLst><p:sldId id="256" r:id="rId2"/><p:sldId id="257" r:id="rId3"/></p:sldIdLst></p:presentation>"#,
            "ppt/_rels/presentation.xml.rels": #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide2.xml"/></Relationships>"#,
            "ppt/slides/slide1.xml": #"<p:sld xmlns:p="x" xmlns:a="y"><a:t>One</a:t></p:sld>"#,
            "ppt/slides/slide2.xml": #"<p:sld xmlns:p="x" xmlns:a="y"><a:t>Two</a:t></p:sld>"#,
        ])
        let snapshot = try OfficeOutputSnapshot.capture(url: url)
        #expect(snapshot.slideCount == 2)
        #expect(snapshot.slideNumbersInOrder == [1, 2])
        #expect(snapshot.slideTexts.contains("One"))
        try OfficeOutputValidator.verify(before: nil, after: snapshot, expectations: [.pptSlideOrder([1, 2])])
        #expect(throws: OfficeOutputValidationError.self) {
            try OfficeOutputValidator.verify(before: nil, after: snapshot, expectations: [.pptSlideOrder([2, 1])])
        }
        #expect(OfficeOutputExpectation.move([1, 2, 3], from: 1, to: 3) == [2, 3, 1])
        #expect(OfficeOutputExpectation.move([1, 2, 3], from: 3, to: 1) == [3, 1, 2])
    }

    @Test("package image replacement preserves the member and verifies bytes")
    func imageReplacement() throws {
        // 1x1 PNG.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        let url = try temporaryURL("deck.pptx")
        let archive = try Archive(url: url, accessMode: .create)
        try archive.addFloeEntry(path: "[Content_Types].xml", data: Data("<Types/>".utf8))
        try archive.addFloeEntry(path: "ppt/slides/slide1.xml", data: Data("<p:sld/>".utf8))
        try archive.addFloeEntry(path: "ppt/media/image1.png", data: png)
        let original = try OfficeOutputSnapshot.capture(url: url)
        let replacement = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let after = try OfficePackageEdits.replaceImage(
            url: url,
            OfficeImageReplacement(target: "ppt/media/image1.png", imageData: replacement),
            expectedSHA256: original.sha256)
        #expect(after.sha256 != original.sha256)
        let package = try OfficeArchive(url: url, maximumEntries: 64)
        #expect(try package.data(path: "ppt/media/image1.png", limit: 1_024) == replacement)
        // A JPEG replacement for a PNG member is refused rather than renaming
        // the part/relationship silently.
        #expect(throws: OfficePackageEdits.ImageError.self) {
            _ = try OfficePackageEdits.replaceImage(
                url: url,
                OfficeImageReplacement(target: "ppt/media/image1.png",
                                       imageData: Data([0xFF, 0xD8, 0xFF, 0xE0])))
        }
    }
}
