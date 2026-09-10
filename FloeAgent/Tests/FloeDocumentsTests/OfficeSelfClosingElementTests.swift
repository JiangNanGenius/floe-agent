import Foundation
import Testing
import ZIPFoundation
import FloeCore
@testable import FloeDocuments

/// Regression: the bounded XML scanner used to treat self-closing elements
/// (`<w:p/>`, `<c r="B3" s="7"/>`, `<a:p/>`) as open elements and swallowed
/// everything up to the next closing tag, misaligning extraction and
/// corrupting later edits.
@Suite("FloeDocuments.Office self-closing elements")
struct OfficeSelfClosingElementTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-office-selfclosing-\(UUID().uuidString)", isDirectory: true)
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

    private func rawXML(_ url: URL, path: String) throws -> String {
        let archive = try Archive(url: url, accessMode: .read)
        guard let entry = archive[path] else { throw OfficeDocumentError.missingEntry(path) }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return String(decoding: data, as: UTF8.self)
    }

    @Test("docx: empty self-closed paragraphs no longer swallow their siblings")
    func wordSelfClosingParagraphs() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("brief.docx")
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\
        <w:p><w:r><w:t>Alpha</w:t></w:r></w:p>\
        <w:p/>\
        <w:p><w:r><w:t>Beta</w:t></w:r></w:p>\
        <w:p><w:r><w:t/></w:r></w:p>\
        <w:p><w:r><w:t>Gamma</w:t></w:r></w:p>\
        </w:body></w:document>
        """
        try makePackage(at: url, members: ["word/document.xml": document])

        let snapshot = try OfficeDocumentService.inspect(url: url)
        #expect(snapshot.fields.map(\.text) == ["Alpha", "Beta", "Gamma"])

        let beta = try #require(snapshot.fields.first(where: { $0.text == "Beta" }))
        let updated = try OfficeDocumentService.update(sourceURL: url, updates: [beta.id: "Beta2"])
        #expect(updated.fields.map(\.text) == ["Alpha", "Beta2", "Gamma"])

        let raw = try rawXML(url, path: "word/document.xml")
        #expect(raw.contains("<w:p/>"))
        #expect(raw.contains("<w:t/>"))
        #expect(raw.contains("<w:t>Alpha</w:t>"))
        #expect(raw.contains("<w:t>Gamma</w:t>"))
    }

    @Test("xlsx: styled empty cells keep their own reference and value")
    func workbookSelfClosingCells() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("model.xlsx")
        let sheet = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\
        <row r="1"><c r="A1" t="inlineStr"><is><t>H1</t></is></c><c r="B1" s="1"/><c r="C1"><v>42</v></c></row>\
        <row r="2"><c r="A2"/><c r="B2" t="inlineStr"><is><t>Keep</t></is></c></row>\
        </sheetData></worksheet>
        """
        try makePackage(at: url, members: ["xl/worksheets/sheet1.xml": sheet])

        let snapshot = try OfficeDocumentService.inspect(url: url)
        // The swallowed-sibling bug used to report B1 as "42" and A2 as "Keep".
        #expect(snapshot.fields.first(where: { $0.label == "C1" })?.text == "42")
        #expect(snapshot.fields.first(where: { $0.label == "B1" })?.text == "")
        #expect(snapshot.fields.first(where: { $0.label == "A2" })?.text == "")
        #expect(snapshot.fields.first(where: { $0.label == "B2" })?.text == "Keep")

        let b2 = try #require(snapshot.fields.first(where: { $0.label == "B2" }))
        let updated = try OfficeDocumentService.update(sourceURL: url, updates: [b2.id: "Changed"])
        #expect(updated.fields.first(where: { $0.label == "B2" })?.text == "Changed")
        #expect(updated.fields.first(where: { $0.label == "C1" })?.text == "42")

        let raw = try rawXML(url, path: "xl/worksheets/sheet1.xml")
        #expect(raw.contains(#"<c r="A2"/>"#))
        #expect(raw.contains(#"<c r="B1" s="1"/>"#))
    }

    @Test("pptx: self-closed drawing paragraphs do not merge slide text")
    func presentationSelfClosingParagraphs() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("deck.pptx")
        let slide = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:sp><p:txBody>\
        <a:p><a:r><a:t>First</a:t></a:r></a:p>\
        <a:p/>\
        <a:p><a:r><a:t>Second</a:t></a:r></a:p>\
        </p:txBody></p:sp></p:spTree></p:cSld></p:sld>
        """
        try makePackage(at: url, members: ["ppt/slides/slide1.xml": slide])

        let snapshot = try OfficeDocumentService.inspect(url: url)
        #expect(snapshot.fields.map(\.text) == ["First", "Second"])

        let second = try #require(snapshot.fields.first(where: { $0.text == "Second" }))
        let updated = try OfficeDocumentService.update(sourceURL: url, updates: [second.id: "Second2"])
        #expect(updated.fields.map(\.text) == ["First", "Second2"])
        #expect(try rawXML(url, path: "ppt/slides/slide1.xml").contains("<a:p/>"))
    }
}
