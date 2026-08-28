import Foundation
import Testing
import ZIPFoundation
import FloeCore
import FloeTools
@testable import FloeDocuments

@Suite("FloeDocuments.Office")
struct OfficeDocumentTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-office-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("native builders create inspectable editable Office packages")
    func buildersAndInspection() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let docx = root.appendingPathComponent("brief.docx")
        try OfficeDocumentBuilder.createWord(
            at: docx, title: "Launch brief", paragraphs: ["First paragraph", "第二段"]
        )
        let word = try OfficeDocumentService.inspect(url: docx)
        #expect(word.kind == .word)
        #expect(word.fields.map(\.text).contains("Launch brief"))
        #expect(word.fields.map(\.text).contains("第二段"))

        let xlsx = root.appendingPathComponent("model.xlsx")
        try OfficeDocumentBuilder.createWorkbook(
            at: xlsx,
            sheets: [.init(name: "Inputs", rows: [["Metric", "Value"], ["Revenue", "42"], ["Double", "=B2*2"]])]
        )
        let workbook = try OfficeDocumentService.inspect(url: xlsx)
        #expect(workbook.kind == .workbook)
        #expect(workbook.fields.contains(where: { $0.label == "B3" && $0.text == "=B2*2" }))

        let pptx = root.appendingPathComponent("deck.pptx")
        try OfficeDocumentBuilder.createPresentation(
            at: pptx,
            title: "Deck",
            slides: [.init(title: "Opening", bullets: ["One", "Two"], notes: "[Sources] https://example.com")]
        )
        let deck = try OfficeDocumentService.inspect(url: pptx)
        #expect(deck.kind == .presentation)
        #expect(deck.fields.map(\.text).contains("Opening"))
        #expect(deck.fields.map(\.text).contains("One"))
        #expect(deck.fields.map(\.text).contains("[Sources] https://example.com"))
    }

    @Test("exact update preserves unedited package members")
    func updatePreservesPackage() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("preserve.docx")
        try OfficeDocumentBuilder.createWord(at: source, title: "Before", paragraphs: ["Keep"])

        let original = try Archive(url: source, accessMode: .read)
        let stylesBefore = try read(original, path: "word/styles.xml")
        let snapshot = try OfficeDocumentService.inspect(url: source)
        let field = try #require(snapshot.fields.first(where: { $0.text == "Before" }))
        let updated = try OfficeDocumentService.update(sourceURL: source, updates: [field.id: "After"])

        #expect(updated.fields.map(\.text).contains("After"))
        let rewritten = try Archive(url: source, accessMode: .read)
        #expect(try read(rewritten, path: "word/styles.xml") == stylesBefore)
    }

    @Test("compiled Office tools create, inspect and update within task scope")
    func toolRoundTrip() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = ToolContext(
            runID: UUID(), workspaceRootURL: root,
            allowedWorkspacePaths: ["docs"], cancellation: CancellationToken()
        )
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)

        let create = DocumentCreateWordTool(rootProvider: { root })
        let created = try await create.execute(
            .init(path: "docs/report.docx", title: "Report", paragraphs: ["Body"]),
            context: context
        )
        #expect(created.exitStatus == 0)

        let inspect = OfficeInspectTool(rootProvider: { root })
        let inspected = try await inspect.execute(.init(path: "docs/report.docx"), context: context)
        #expect(inspected.exitStatus == 0)
        #expect(inspected.summary.contains("kind=docx"))

        let snapshot = try OfficeDocumentService.inspect(url: root.appendingPathComponent("docs/report.docx"))
        let title = try #require(snapshot.fields.first(where: { $0.text == "Report" }))
        let update = OfficeUpdateTextTool(rootProvider: { root })
        let changed = try await update.execute(
            .init(path: "docs/report.docx", updates: [title.id: "Updated report"]), context: context
        )
        #expect(changed.exitStatus == 0)
        #expect(try OfficeDocumentService.inspect(url: root.appendingPathComponent("docs/report.docx"))
            .fields.map(\.text).contains("Updated report"))
    }

    @Test("Office tools fail closed outside task scope and on overwrite")
    func boundaries() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = ToolContext(
            runID: UUID(), workspaceRootURL: root,
            allowedWorkspacePaths: ["allowed"], cancellation: CancellationToken()
        )
        let tool = DocumentCreateWorkbookTool(rootProvider: { root })
        let denied = try await tool.execute(
            .init(path: "outside.xlsx", sheets: [.init(name: "Data", rows: [["x"]])]),
            context: context
        )
        #expect(denied.exitStatus == 2)

        try FileManager.default.createDirectory(at: root.appendingPathComponent("allowed"), withIntermediateDirectories: true)
        let existing = root.appendingPathComponent("allowed/existing.xlsx")
        try Data("existing".utf8).write(to: existing)
        let overwrite = try await tool.execute(
            .init(path: "allowed/existing.xlsx", sheets: [.init(name: "Data", rows: [["x"]])]),
            context: context
        )
        #expect(overwrite.exitStatus == 2)
        #expect(try Data(contentsOf: existing) == Data("existing".utf8))
    }

    private func read(_ archive: Archive, path: String) throws -> Data {
        let entry = try #require(archive[path])
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return data
    }
}
