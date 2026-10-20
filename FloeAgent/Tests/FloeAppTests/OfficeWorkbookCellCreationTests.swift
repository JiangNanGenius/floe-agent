// FloeAppTests — Office workbook blank-cell creation through the EXISTING
// OfficeDocumentService OOXML rewrite pipeline
// (update(sourceURL:updates:expectedSHA256:allowsWorkbookCellCreation:)).
//
// Every package in this suite is a clearly labelled SYNTHETIC OOXML
// preservation fixture built in a temporary directory. It proves only the
// core codec contract: default unknown-field refusal, the bounded creation
// opt-in (numeric `<v>`, formula `<f>`, inline text), value/reference/path
// validation, stale-digest protection and member preservation. It is NOT
// physical-device, live-engine or Pencil-ink evidence: the real mounted
// NotesOfficeView session, handwritten-ink preservation and the Collabora
// SUM(C1:C15)=120 readback are separate App/device qualifications owned by
// the primary (OfficeLiveInkAppQualificationTests). No Notes or
// ThreadDetailViewModel orchestration is duplicated here.
//
// Job scope: job-1e41e5e931a348a6 (core-cell-writer). The worker only
// parse-checks this file; compiling and running it is the primary's App
// build gate. FloeAppTests uses an explicit project.yml source list — the
// primary registered this file there and regenerates the Xcode project.

import Foundation
import Testing
import ZIPFoundation
import FloeDocuments

@Suite("FloeApp.Office workbook cell creation")
struct OfficeWorkbookCellCreationTests {
    private static let sheet1Entry = "xl/worksheets/sheet1.xml"

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-office-cell-creation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makePackage(at url: URL, members: [String: String]) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (path, text) in members.sorted(by: { $0.key < $1.key }) {
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

    private func rawMember(_ url: URL, path: String) throws -> Data {
        let archive = try Archive(url: url, accessMode: .read)
        guard let entry = archive[path] else { throw CocoaError(.fileNoSuchFile) }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return data
    }

    private func rawText(_ url: URL, path: String) throws -> String {
        String(decoding: try rawMember(url, path: path), as: UTF8.self)
    }

    // MARK: - Synthetic fixtures

    /// A workbook head that `XLSXWorkbookPreviewReader` resolves: the single
    /// sheet's relationship points at exactly the one worksheet member.
    private var workbookXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets><sheet name="Numbers" sheetId="1" r:id="rId1"/></sheets></workbook>
        """
    }

    private var workbookRels: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>\
        </Relationships>
        """
    }

    private var contentTypes: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
        <Override PartName="/xl/drawings/drawing1.xml" ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/>\
        </Types>
        """
    }

    private var packageRels: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
        </Relationships>
        """
    }

    private var stylesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="1"><font/></fonts></styleSheet>
        """
    }

    private var sharedStringsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="1" uniqueCount="1"><si><t>Total</t></si></sst>
        """
    }

    /// A labelled synthetic stand-in for saved Pencil ink: opaque package
    /// bytes the creation pass must carry over byte-for-byte. It is NOT real
    /// device ink; live-ink preservation is the primary's native acceptance.
    private var drawingXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
        <xdr:wsDr xmlns:xdr="http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing"><xdr:absoluteAnchor><xdr:ext cx="12700" cy="12700"/><xdr:pic><xdr:nvPicPr><xdr:cNvPr id="2" name="synthetic-ink-fixture"/></xdr:nvPicPr></xdr:pic></xdr:absoluteAnchor></xdr:wsDr>
        """
    }

    private var drawingRels: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing" Target="../drawings/drawing1.xml"/>\
        </Relationships>
        """
    }

    /// The user-acceptance starting state: saved A1=11111, B1=123456, a
    /// pre-existing styled formula cell, a shared-string label and an ink
    /// drawing relationship. Rows 1/2/5 exist; rows 3,4,6… are absent.
    private var baseWorksheet: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <dimension ref="A1:E5"/><sheetData>\
        <row r="1" spans="1:4"><c r="A1"><v>11111</v></c><c r="B1" s="1"><v>123456</v></c></row>\
        <row r="2" spans="1:4"><c r="A2" s="2"><f>SUM(A1,B1)</f><v>134567</v></c><c r="D2" t="s"><v>0</v></c></row>\
        <row r="5" spans="5:5"><c r="E5" s="2"/></row>\
        </sheetData><drawing r:id="rId1"/></worksheet>
        """
    }

    private func baseMembers(worksheet: String? = nil) -> [String: String] {
        [
            "[Content_Types].xml": contentTypes,
            "_rels/.rels": packageRels,
            "xl/workbook.xml": workbookXML,
            "xl/_rels/workbook.xml.rels": workbookRels,
            "xl/styles.xml": stylesXML,
            "xl/sharedStrings.xml": sharedStringsXML,
            "xl/worksheets/sheet1.xml": worksheet ?? baseWorksheet,
            "xl/worksheets/_rels/sheet1.xml.rels": drawingRels,
            "xl/drawings/drawing1.xml": drawingXML,
        ]
    }

    private func makeWorkbook(
        in root: URL,
        named name: String = "model.xlsx",
        worksheet: String? = nil,
        extraMembers: [String: String] = [:]
    ) throws -> URL {
        var members = baseMembers(worksheet: worksheet)
        for (path, text) in extraMembers { members[path] = text }
        let url = root.appendingPathComponent(name)
        try makePackage(at: url, members: members)
        return url
    }

    private func cellID(_ reference: String) -> String {
        "\(Self.sheet1Entry)|c|\(reference)"
    }

    private enum CreationRefusal {
        case none, unknownField, invalidContent, revisionConflict
    }

    private func classify(_ block: () throws -> Any) -> CreationRefusal {
        do {
            _ = try block()
            return .none
        } catch OfficeDocumentError.unknownField {
            return .unknownField
        } catch OfficeDocumentError.invalidContent {
            return .invalidContent
        } catch OfficeDocumentError.revisionConflict {
            return .revisionConflict
        } catch {
            Issue.record("Unexpected non-Office error: \(error)")
            return .none
        }
    }

    // MARK: - Default behavior stays unchanged

    @Test("without the opt-in an absent canonical cell keeps the unknown-field refusal")
    func defaultRefusesAbsentCell() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeWorkbook(in: root)
        let before = try Data(contentsOf: url)
        let snapshot = try OfficeDocumentService.inspect(url: url)
        // The exact old selector — no new argument — must still compile and
        // must still refuse a cell the package does not have.
        #expect(classify {
            try OfficeDocumentService.update(
                sourceURL: url, updates: [cellID("C1"): "1"], expectedSHA256: snapshot.sha256
            )
        } == .unknownField)
        // …and the opt-in=false spelling explicitly.
        #expect(classify {
            try OfficeDocumentService.update(
                sourceURL: url, updates: [cellID("C1"): "1"],
                expectedSHA256: snapshot.sha256, allowsWorkbookCellCreation: false
            )
        } == .unknownField)
        #expect(try Data(contentsOf: url) == before)
        // Existing-cell edits still work unchanged under the default.
        let known = try #require(snapshot.fields.first(where: { $0.id == cellID("A1") }))
        #expect(known.text == "11111")
        _ = try OfficeDocumentService.update(
            sourceURL: url, updates: [known.id: "9"], expectedSHA256: try OfficeDocumentService.inspect(url: url).sha256
        )
    }

    // MARK: - Opt-in creation contract (user acceptance scenario)

    @Test("opt-in creates C1:C15 numeric cells and the C16 SUM through the same writer, with real readback")
    func createsNumericCellsAndFormula() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeWorkbook(in: root)
        let before = try OfficeDocumentService.inspect(url: url)
        #expect(before.sha256 != nil)
        var updates: [String: String] = [:]
        for number in 1...15 {
            updates[cellID("C\(number)")] = String(number)
        }
        updates[cellID("C16")] = "=SUM(C1:C15)"
        let updated = try OfficeDocumentService.update(
            sourceURL: url, updates: updates,
            expectedSHA256: before.sha256, allowsWorkbookCellCreation: true
        )
        let fields = Dictionary(uniqueKeysWithValues: updated.fields.map { ($0.id, $0.text) })
        for number in 1...15 {
            #expect(fields[cellID("C\(number)")] == String(number), "C\(number) readback")
        }
        #expect(fields[cellID("C16")] == "=SUM(C1:C15)")
        // Numeric values are real <v> numbers, never inline text SUM ignores.
        let raw = try rawText(url, path: Self.sheet1Entry)
        #expect(raw.contains(#"<c r="C1"><v>1</v></c></row>"#))
        #expect(raw.contains(#"<c r="C2"><v>2</v></c><c r="D2" t="s"><v>0</v></c>"#))
        #expect(raw.contains(#"<row r="3"><c r="C3"><v>3</v></c></row>"#))
        #expect(raw.contains(#"<row r="16"><c r="C16"><f>SUM(C1:C15)</f></c></row>"#))
        #expect(!raw.contains(#"<c r="C1" t="inlineStr""#))
        // No fabricated cached result on the formula.
        #expect(raw.contains("<f>SUM(C1:C15)</f></c>"))
        #expect(!raw.contains("<f>SUM(C1:C15)</f><v>"))
        // Pre-existing saved cells, styles and the old formula survive.
        #expect(raw.contains(#"<c r="A1"><v>11111</v></c>"#))
        #expect(raw.contains(#"<c r="B1" s="1"><v>123456</v></c>"#))
        #expect(raw.contains(#"<c r="A2" s="2"><f>SUM(A1,B1)</f><v>134567</v></c>"#))
        #expect(fields[cellID("A1")] == "11111")
        #expect(fields[cellID("B1")] == "123456")
        #expect(fields[cellID("A2")] == "=SUM(A1,B1)")
        #expect(fields[cellID("D2")] == "Total")
        // Row/cell order: new rows sort after row 5; the modified row 5 keeps
        // E5 and its style, C5 lands in column order, stale spans is dropped.
        #expect(raw.contains(#"<row r="5"><c r="C5"><v>5</v></c><c r="E5" s="2"/></row>"#))
        #expect(raw.contains(#"<row r="1" spans="1:4">"#))
        #expect(raw.contains(#"<row r="2" spans="1:4">"#))
        if let five = raw.range(of: #"<row r="5">"#), let sixteen = raw.range(of: #"<row r="16">"#) {
            #expect(five.lowerBound < sixteen.lowerBound)
        } else {
            Issue.record("missing rows in rewritten worksheet")
        }
        // Dimension widened to cover C16 (column cap stays E from E5).
        #expect(raw.contains(#"<dimension ref="A1:E16"/>"#))
        // The written digest differs and re-inspection reads the same cells.
        #expect(updated.sha256 != before.sha256)
        let reread = try OfficeDocumentService.inspect(url: url)
        #expect(reread.fields.filter { $0.id.hasSuffix("|c|C16") }.map(\.text) == ["=SUM(C1:C15)"])
    }

    @Test("creation streams every unrelated package member unchanged (styles, shared strings, rels, synthetic drawing)")
    func creationPreservesOtherMembers() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeWorkbook(in: root)
        var before: [String: Data] = [:]
        for path in [
            "[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels",
            "xl/styles.xml", "xl/sharedStrings.xml", "xl/worksheets/_rels/sheet1.xml.rels",
            "xl/drawings/drawing1.xml",
        ] {
            before[path] = try rawMember(url, path: path)
        }
        let snapshot = try OfficeDocumentService.inspect(url: url)
        _ = try OfficeDocumentService.update(
            sourceURL: url,
            updates: [cellID("C1"): "1", cellID("C16"): "=SUM(C1:C1)"],
            expectedSHA256: snapshot.sha256,
            allowsWorkbookCellCreation: true
        )
        for (path, data) in before {
            #expect(try rawMember(url, path: path) == data, "\(path) changed")
        }
    }

    @Test("digit-free text still creates as preserved inline text")
    func plainTextCellCreatedAsInlineStr() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeWorkbook(in: root)
        let snapshot = try OfficeDocumentService.inspect(url: url)
        let updated = try OfficeDocumentService.update(
            sourceURL: url, updates: [cellID("H1"): "Grand total"],
            expectedSHA256: snapshot.sha256, allowsWorkbookCellCreation: true
        )
        #expect(updated.fields.first(where: { $0.id == cellID("H1") })?.text == "Grand total")
        let raw = try rawText(url, path: Self.sheet1Entry)
        #expect(raw.contains(#"<c r="H1" t="inlineStr"><is><t xml:space="preserve">Grand total</t></is></c>"#))
    }

    @Test("insertion order, spans drop and dimension widening inside an existing row")
    func rowOrderSpansAndDimension() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeWorkbook(in: root)
        let snapshot = try OfficeDocumentService.inspect(url: url)
        _ = try OfficeDocumentService.update(
            sourceURL: url,
            updates: [cellID("B5"): "2", cellID("F5"): "6"],
            expectedSHA256: snapshot.sha256,
            allowsWorkbookCellCreation: true
        )
        let raw = try rawText(url, path: Self.sheet1Entry)
        // B5 before E5, F5 after E5, spans="5:5" no longer covers 2/6 → dropped.
        #expect(raw.contains(#"<row r="5"><c r="B5"><v>2</v></c><c r="E5" s="2"/><c r="F5"><v>6</v></c></row>"#))
        #expect(raw.contains(#"<dimension ref="A1:F5"/>"#))
        let reread = try OfficeDocumentService.inspect(url: url)
        let fields = Dictionary(uniqueKeysWithValues: reread.fields.map { ($0.id, $0.text) })
        #expect(fields[cellID("B5")] == "2")
        #expect(fields[cellID("F5")] == "6")
    }

    @Test("a self-closed sheetData worksheet gains its rows")
    func selfClosedSheetData() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let emptySheet = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><dimension ref="A1"/><sheetData/></worksheet>
        """
        let url = try makeWorkbook(in: root, worksheet: emptySheet)
        let snapshot = try OfficeDocumentService.inspect(url: url)
        _ = try OfficeDocumentService.update(
            sourceURL: url, updates: [cellID("B7"): "7"],
            expectedSHA256: snapshot.sha256, allowsWorkbookCellCreation: true
        )
        let raw = try rawText(url, path: Self.sheet1Entry)
        #expect(raw.contains(#"<sheetData><row r="7"><c r="B7"><v>7</v></c></row></sheetData>"#))
        #expect(raw.contains(#"<dimension ref="A1:B7"/>"#))
        let reread = try OfficeDocumentService.inspect(url: url)
        #expect(reread.fields.first(where: { $0.id == cellID("B7") })?.text == "7")
    }

    // MARK: - Fail-closed refusals

    @Test("stale expected digests are refused with the file untouched")
    func staleDigestRefused() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeWorkbook(in: root)
        let original = try Data(contentsOf: url)
        #expect(classify {
            try OfficeDocumentService.update(
                sourceURL: url, updates: [cellID("C1"): "1"],
                expectedSHA256: String(repeating: "0", count: 64), allowsWorkbookCellCreation: true
            )
        } == .revisionConflict)
        let before = try OfficeDocumentService.inspect(url: url)
        _ = try OfficeDocumentService.update(
            sourceURL: url, updates: [cellID("C1"): "1"],
            expectedSHA256: before.sha256, allowsWorkbookCellCreation: true
        )
        // The pre-creation digest is now stale; a second creation must not land.
        let current = try Data(contentsOf: url)
        #expect(classify {
            try OfficeDocumentService.update(
                sourceURL: url, updates: [cellID("C2"): "2"],
                expectedSHA256: before.sha256, allowsWorkbookCellCreation: true
            )
        } == .revisionConflict)
        #expect(try Data(contentsOf: url) == current)
    }

    @Test("numeric look-alikes, unsafe values and foreign keys are refused without touching the file")
    func unsafeValuesAndKeysRefused() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeWorkbook(in: root)
        let original = try Data(contentsOf: url)
        let snapshot = try OfficeDocumentService.inspect(url: url)
        let badValues = [
            "007", "1,000", "inf", "-inf", "nan", "0x1p3", "+5", ".5", "5.", "1e", "12%",
            "Q1", "total2", "=", "=   ", "", "\u{0001}bad", "x".repeating(to: 65_537),
        ]
        for value in badValues {
            let id = cellID("C20")
            #expect(classify {
                try OfficeDocumentService.update(
                    sourceURL: url, updates: [id: value],
                    expectedSHA256: snapshot.sha256, allowsWorkbookCellCreation: true
                )
            } == .invalidContent, "value \(value.debugDescription) must be refused")
        }
        let badKeys: [(key: String, value: String)] = [
            (cellID("c20"), "1"),          // lowercase reference
            (cellID("A0"), "1"),           // zero row
            (cellID("XFG1"), "1"),         // beyond XFD
            (cellID("A1048577"), "1"),     // beyond the last row
            (cellID("C20 "), "1"),         // trailing space
            (cellID("$C$20"), "1"),        // absolute form is not the canonical key
            ("\(Self.sheet1Entry)|c|C20|c|D21", "1"),
            ("xl/worksheets/sheet2.xml|c|C20", "1"),   // member does not exist
            ("xl/workbook.xml|c|C20", "1"),            // not a worksheet
            ("xl/worksheets/_rels/sheet1.xml.rels|c|C20", "1"),
            ("../evil|c|C20", "1"),                    // path never comes from the model
            ("word/document.xml|p|0", "1"),            // paragraph creation does not exist
        ]
        for (key, value) in badKeys {
            #expect(classify {
                try OfficeDocumentService.update(
                    sourceURL: url, updates: [key: value],
                    expectedSHA256: snapshot.sha256, allowsWorkbookCellCreation: true
                )
            } == .unknownField, "key \(key.debugDescription) must keep the unknown-field refusal")
        }
        // An oversized batch is refused too (limit 2000 cells per update).
        var overflow: [String: String] = [:]
        for number in 1...2_001 {
            overflow[cellID("K\(number)")] = "1"
        }
        #expect(classify {
            try OfficeDocumentService.update(
                sourceURL: url, updates: overflow,
                expectedSHA256: snapshot.sha256, allowsWorkbookCellCreation: true
            )
        } == .invalidContent)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("a package whose sheet relationships do not resolve never creates cells")
    func unresolvedWorkbookRelationshipRefused() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // sheet2.xml exists in the package but xl/workbook.xml references only
        // sheet1 — the read-only resolver refuses to guess, so creation cannot
        // treat model-adjacent parts as sheets.
        let straySheet = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1"><v>1</v></c></row></sheetData></worksheet>
        """
        let url = try makeWorkbook(in: root, extraMembers: ["xl/worksheets/sheet2.xml": straySheet])
        let original = try Data(contentsOf: url)
        let snapshot = try OfficeDocumentService.inspect(url: url)
        #expect(snapshot.workbookPreview == nil)
        #expect(classify {
            try OfficeDocumentService.update(
                sourceURL: url, updates: [cellID("C3"): "1"],
                expectedSHA256: snapshot.sha256, allowsWorkbookCellCreation: true
            )
        } == .invalidContent)
        // Targeting the stray part is refused too: the package-level
        // relationship gate fails closed before any path is chosen, so the
        // whole opt-in batch — not just the sheet2 key — is rejected.
        #expect(classify {
            try OfficeDocumentService.update(
                sourceURL: url, updates: ["xl/worksheets/sheet2.xml|c|B2": "1"],
                expectedSHA256: snapshot.sha256, allowsWorkbookCellCreation: true
            )
        } == .invalidContent)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("a worksheet with positional row/cell references fails closed instead of reinterpreting")
    func positionalStructureRefused() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let positional = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\
        <row><c><v>3</v></c></row>\
        </sheetData></worksheet>
        """
        let url = try makeWorkbook(in: root, worksheet: positional)
        let original = try Data(contentsOf: url)
        let snapshot = try OfficeDocumentService.inspect(url: url)
        #expect(classify {
            try OfficeDocumentService.update(
                sourceURL: url, updates: [cellID("C3"): "1"],
                expectedSHA256: snapshot.sha256, allowsWorkbookCellCreation: true
            )
        } == .invalidContent)
        #expect(try Data(contentsOf: url) == original)
    }
}

private extension String {
    func repeating(to count: Int) -> String {
        String(repeating: self, count: count)
    }
}
