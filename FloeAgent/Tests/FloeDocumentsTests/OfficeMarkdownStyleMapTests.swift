// FloeDocumentsTests — the real DOCX→Markdown semantic Title contract.
//
// The conversion engine is the pinned Mammoth build; it reads an embedded
// `mammoth/style-map` member. These tests build real packages with the
// production builder and assert the in-memory prepared copy, never a source
// rewrite. The actual HTML conversion is qualified in the App test host.

import Foundation
import Testing
import ZIPFoundation
import FloeCore
@testable import FloeDocuments

@Suite("Office Markdown style-map preparation")
struct OfficeMarkdownStyleMapTests {
    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-markdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func member(_ url: URL, _ path: String) throws -> Data? {
        let archive = try Archive(url: url, accessMode: .read)
        guard let entry = archive[path] else { return nil }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return data
    }

    @Test("a generated Word Title gets an embedded H1 mapping without touching document.xml")
    func titleMappingIsAdded() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("title.docx")
        try OfficeDocumentBuilder.createWord(at: url, title: "Quarterly Review",
                                             paragraphs: ["Body paragraph."])
        let source = try Data(contentsOf: url)
        let originalDocument = try #require(try member(url, "word/document.xml"))

        let outcome = try OfficeMarkdownStyleMap.addingTitleHeadingMap(to: source)
        #expect(outcome.titleMappingPresent)
        #expect(!outcome.authoredMapPreserved)
        #expect(outcome.rewrotePackage)
        #expect(outcome.data.count > source.count)

        let prepared = root.appendingPathComponent("title-prepared.docx")
        try outcome.data.write(to: prepared)
        let styleMap = try #require(try member(prepared, OfficeMarkdownStyleMap.partName))
        let text = try #require(String(data: styleMap, encoding: .utf8))
        #expect(text.contains("p.Title => h1:fresh"))
        #expect(text.contains("p[style-name='Title'] => h1:fresh"))
        // The document content/package bytes are otherwise preserved.
        #expect(try member(prepared, "word/document.xml") == originalDocument)
        let originalArchive = try Archive(url: url, accessMode: .read)
        let preparedArchive = try Archive(url: prepared, accessMode: .read)
        #expect(Set(originalArchive.map(\.path)).isSubset(of: Set(preparedArchive.map(\.path))))

        // The source file is not modified by preparing the in-memory copy.
        #expect(try Data(contentsOf: url) == source)
        // A repeated preparation is an idempotent no-op.
        let again = try OfficeMarkdownStyleMap.addingTitleHeadingMap(to: outcome.data)
        #expect(!again.rewrotePackage)
        #expect(again.data == outcome.data)
    }

    @Test("an authored style map is preserved and its explicit Title mapping wins")
    func authoredMapWins() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("base.docx")
        try OfficeDocumentBuilder.createWord(at: base, title: "Authored", paragraphs: ["Text"])

        // No Title in the authored map: keep its lines first, then add ours.
        let noTitle = root.appendingPathComponent("authored-no-title.docx")
        try copy(base, to: noTitle, styleMap: "p[style-name='Caption'] => p:fresh\n")
        let merged = try OfficeMarkdownStyleMap.addingTitleHeadingMap(
            to: try Data(contentsOf: noTitle))
        #expect(merged.rewrotePackage)
        #expect(merged.authoredMapPreserved)
        let mergedURL = root.appendingPathComponent("merged.docx")
        try merged.data.write(to: mergedURL)
        let mergedMap = try #require(try member(mergedURL, OfficeMarkdownStyleMap.partName))
        let mergedText = try #require(String(data: mergedMap, encoding: .utf8))
        #expect(mergedText.hasPrefix("p[style-name='Caption'] => p:fresh\n"))
        #expect(mergedText.contains("p.Title => h1:fresh"))

        // A Title mapping already authored by the document is authoritative.
        let authored = root.appendingPathComponent("authored-title.docx")
        try copy(base, to: authored, styleMap: "p.Title => p:fresh\n")
        let original = try Data(contentsOf: authored)
        let preserved = try OfficeMarkdownStyleMap.addingTitleHeadingMap(to: original)
        #expect(preserved.titleMappingPresent)
        #expect(preserved.authoredMapPreserved)
        #expect(!preserved.rewrotePackage)
        #expect(preserved.data == original)
    }

    @Test("non-ZIP and oversized inputs fail closed")
    func invalidInputs() throws {
        #expect(throws: FloeError.self) {
            _ = try OfficeMarkdownStyleMap.addingTitleHeadingMap(
                to: Data("not a package".utf8))
        }
        #expect(throws: FloeError.self) {
            _ = try OfficeMarkdownStyleMap.addingTitleHeadingMap(
                to: Data(count: 17 * 1_024 * 1_024))
        }
    }

    private func copy(_ source: URL, to destination: URL, styleMap: String) throws {
        let input = try Archive(url: source, accessMode: .read)
        let output = try Archive(url: destination, accessMode: .create)
        for entry in input where entry.type == .file {
            var data = Data()
            _ = try input.extract(entry) { data.append($0) }
            try output.addFloeEntry(path: entry.path, data: data)
        }
        try output.addFloeEntry(path: OfficeMarkdownStyleMap.partName,
                                data: Data(styleMap.utf8))
    }
}
