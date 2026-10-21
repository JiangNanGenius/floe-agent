import Foundation
import Testing
import ZIPFoundation
@testable import FloeDocuments

@Suite("Embedded chart workbook formatting")
struct OfficeEmbeddedWorkbookPreservationTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chart-merge-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func workbook(_ url: URL, engine: Bool, value: String = "14", extra: Bool = false, deleted: Bool = false, formula: Bool = false) throws {
        let archive = try Archive(url: url, accessMode: .create), s = OfficeXMLNamespace.sheet, r = OfficeXMLNamespace.officeRelationships
        let members = [
            "xl/workbook.xml": "<workbook xmlns=\"\(s)\" xmlns:r=\"\(r)\"><sheets><sheet name=\"Data\" sheetId=\"1\" r:id=\"sheet\"/></sheets></workbook>",
            "xl/_rels/workbook.xml.rels": "<Relationships xmlns=\"\(OfficeXMLNamespace.relationships)\"><Relationship Id=\"sheet\" Type=\"\(r)/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>",
            "xl/styles.xml": engine ? "<styleSheet xmlns=\"\(s)\"><fonts count=\"1\"><font><name val=\"Normalized\"/></font></fonts><cellXfs count=\"1\"><xf fontId=\"0\"/></cellXfs></styleSheet>" : "<styleSheet xmlns=\"\(s)\"><fonts count=\"2\"><font><name val=\"Default\"/></font><font><name val=\"Original Font\"/></font></fonts><cellXfs count=\"2\"><xf fontId=\"0\"/><xf fontId=\"1\"/></cellXfs></styleSheet>",
            "xl/sharedStrings.xml": engine ? "<sst xmlns=\"\(s)\"><si><t>Unused</t></si><si><t>Label</t></si></sst>" : "<sst xmlns=\"\(s)\"><si><t>Label</t></si></sst>",
            "xl/worksheets/sheet1.xml": "<worksheet xmlns=\"\(s)\"><dimension ref=\"A1:B1\"/><sheetData><row r=\"1\">" + (deleted ? "" : "<c r=\"A1\" s=\"\(engine ? 0 : 1)\">\(formula ? "<f>1+1</f>" : "")<v>\(engine ? value : "12")</v></c>") + "<c r=\"B1\" s=\"\(engine ? 0 : 1)\" t=\"s\"><v>\(engine ? 1 : 0)</v></c>\(extra ? "<c r=\"C1\" s=\"0\"><v>27</v></c>" : "")</row></sheetData></worksheet>"
        ]
        for key in members.keys.sorted() { try archive.addFloeEntry(path: key, data: Data(members[key]!.utf8)) }
    }
    private func deck(_ url: URL, workbook: URL) throws {
        let archive = try Archive(url: url, accessMode: .create), c = "http://schemas.openxmlformats.org/drawingml/2006/chart"
        try archive.addFloeEntry(path: "ppt/charts/chart1.xml", data: Data("<c:chartSpace xmlns:c=\"\(c)\" xmlns:r=\"\(OfficeXMLNamespace.officeRelationships)\"><c:chart><c:numRef><c:f>Data!$A$1</c:f></c:numRef></c:chart><c:externalData r:id=\"book\"/></c:chartSpace>".utf8))
        try archive.addFloeEntry(path: "ppt/charts/_rels/chart1.xml.rels", data: Data("<Relationships xmlns=\"\(OfficeXMLNamespace.relationships)\"><Relationship Id=\"book\" Type=\"\(OfficeXMLNamespace.officeRelationships)/package\" Target=\"../embeddings/book.xlsx\"/></Relationships>".utf8))
        try archive.addFloeEntry(path: "ppt/embeddings/book.xlsx", data: Data(contentsOf: workbook))
    }
    private func extracted(_ deck: URL, directory: URL) throws -> OfficeArchive {
        let outer = try OfficeArchive(url: deck, maximumEntries: 4096)
        let url = directory.appendingPathComponent("extracted-\(UUID()).xlsx")
        try outer.data(path: "ppt/embeddings/book.xlsx", limit: 1_000_000).write(to: url)
        return try OfficeArchive(url: url, maximumEntries: 4096)
    }

    @Test("data edits retain original fonts, cell style indices, shared strings and unrelated members")
    func preservesOriginalFormatting() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let oldBook = dir.appendingPathComponent("old.xlsx"), newBook = dir.appendingPathComponent("new.xlsx")
        let original = dir.appendingPathComponent("old.pptx"), saved = dir.appendingPathComponent("new.pptx")
        try workbook(oldBook, engine: false); try workbook(newBook, engine: true)
        try deck(original, workbook: oldBook); try deck(saved, workbook: newBook)
        _ = try OfficeEmbeddedWorkbookPreservation.preserve(originalURL: original, savedURL: saved)
        let actual = try extracted(saved, directory: dir), old = try OfficeArchive(url: oldBook, maximumEntries: 4096)
        #expect(try actual.data(path: "xl/styles.xml", limit: 100_000) == old.data(path: "xl/styles.xml", limit: 100_000))
        #expect(try actual.data(path: "xl/sharedStrings.xml", limit: 100_000) == old.data(path: "xl/sharedStrings.xml", limit: 100_000))
        let cells = try OfficeExplicitTargets.tree(actual, "xl/worksheets/sheet1.xml").descendants("c", OfficeXMLNamespace.sheet)
        #expect(cells.first { $0.attributes["r"] == "A1" }?.attributes["s"] == "1")
        #expect(cells.first { $0.attributes["r"] == "A1" }?.child("v", OfficeXMLNamespace.sheet)?.text == "14")
        #expect(cells.first { $0.attributes["r"] == "B1" }?.child("v", OfficeXMLNamespace.sheet)?.text == "0")
    }

    @Test("adding series cells uses original default style; deleting data retains original formatted cells")
    func addAndDeleteSeriesData() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let oldBook = dir.appendingPathComponent("old.xlsx"), newBook = dir.appendingPathComponent("new.xlsx")
        let original = dir.appendingPathComponent("old.pptx"), saved = dir.appendingPathComponent("new.pptx")
        try workbook(oldBook, engine: false); try workbook(newBook, engine: true, extra: true, deleted: true)
        try deck(original, workbook: oldBook); try deck(saved, workbook: newBook)
        let facts = try OfficeEmbeddedWorkbookPreservation.preserve(originalURL: original, savedURL: saved)
        #expect(facts.contains { $0.contains("default style: C1") })
        let result = try extracted(saved, directory: dir)
        let cells = try OfficeExplicitTargets.tree(result, "xl/worksheets/sheet1.xml").descendants("c", OfficeXMLNamespace.sheet)
        let removed = cells.first { $0.attributes["r"] == "A1" }, added = cells.first { $0.attributes["r"] == "C1" }
        #expect(removed?.attributes["s"] == "1" && removed?.child("v", OfficeXMLNamespace.sheet) == nil)
        #expect(added?.attributes["s"] == nil && added?.child("v", OfficeXMLNamespace.sheet)?.text == "27")
    }

    @Test("unsupported formula structural changes leave saved copy and original intact")
    func failedPreservationRetainsRawCopies() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let oldBook = dir.appendingPathComponent("old.xlsx"), newBook = dir.appendingPathComponent("new.xlsx")
        let original = dir.appendingPathComponent("old.pptx"), saved = dir.appendingPathComponent("new.pptx")
        try workbook(oldBook, engine: false); try workbook(newBook, engine: true, formula: true)
        try deck(original, workbook: oldBook); try deck(saved, workbook: newBook)
        let originalData = try Data(contentsOf: original), rawData = try Data(contentsOf: saved)
        #expect(throws: (any Error).self) { try OfficeEmbeddedWorkbookPreservation.preserve(originalURL: original, savedURL: saved) }
        #expect(try Data(contentsOf: saved) == rawData)
        #expect(try Data(contentsOf: original) == originalData)
    }

    @Test("post-commit pending journal reconciles published and raw-working digests separately")
    func pendingDigestRecovery() {
        var record = DocumentRecoveryManifest(id: UUID(), originalBookmark: Data([1]), displayName: "Deck", fileExtension: "pptx", committedDigest: String(repeating: "a", count: 64), pendingDigest: String(repeating: "b", count: 64), workingSavedDigest: String(repeating: "a", count: 64), pendingWorkingDigest: String(repeating: "c", count: 64), updatedAt: Date())
        record.reconcileCommittedPending(currentDigest: String(repeating: "d", count: 64))
        #expect(record.committedDigest == String(repeating: "a", count: 64))
        record.reconcileCommittedPending(currentDigest: String(repeating: "b", count: 64))
        #expect(record.committedDigest == String(repeating: "b", count: 64))
        #expect(record.workingSavedDigest == String(repeating: "c", count: 64))
        #expect(record.pendingDigest == nil && record.pendingWorkingDigest == nil)
    }
}
