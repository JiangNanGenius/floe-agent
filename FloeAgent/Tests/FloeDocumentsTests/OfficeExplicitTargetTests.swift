import Foundation
import Testing
import ZIPFoundation
import FloeCore
import FloeTools
@testable import FloeDocuments

@Suite("Office exact saved-package targets")
struct OfficeExplicitTargetTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("office-exact-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func package(_ url: URL, _ entries: [String: String]) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for key in entries.keys.sorted() { try archive.addFloeEntry(path: key, data: Data(entries[key]!.utf8)) }
    }
    private func word(_ url: URL, count: Int = 2) throws {
        let w = OfficeXMLNamespace.word
        let paragraphs = (0..<count).map { "<w:p><w:r><w:t>Paragraph \($0)</w:t></w:r></w:p>" }.joined()
        try package(url, ["word/document.xml": "<w:document xmlns:w=\"\(w)\"><w:body>\(paragraphs)</w:body></w:document>",
            "word/styles.xml": "<w:styles xmlns:w=\"\(w)\"><w:style w:type=\"paragraph\" w:styleId=\"ActualHeading\"><w:name w:val=\"Heading One\"/></w:style></w:styles>",
            "[Content_Types].xml": "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>"])
    }
    private func workbook(_ url: URL) throws {
        let s = OfficeXMLNamespace.sheet, r = OfficeXMLNamespace.officeRelationships
        try package(url, [
            "xl/workbook.xml": "<workbook xmlns=\"\(s)\" xmlns:r=\"\(r)\"><sheets><sheet name=\"SecondFileFirst\" sheetId=\"7\" r:id=\"b\"/><sheet name=\"Target\" sheetId=\"42\" r:id=\"a\"/></sheets></workbook>",
            "xl/_rels/workbook.xml.rels": "<Relationships xmlns=\"\(OfficeXMLNamespace.relationships)\"><Relationship Id=\"a\" Type=\"\(r)/worksheet\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"b\" Type=\"\(r)/worksheet\" Target=\"worksheets/sheet9.xml\"/></Relationships>",
            "xl/worksheets/sheet9.xml": "<worksheet xmlns=\"\(s)\"><sheetData><row r=\"1\"><c r=\"A1\"><v>999</v></c></row></sheetData></worksheet>",
            "xl/worksheets/sheet1.xml": "<worksheet xmlns=\"\(s)\"><sheetData><row r=\"1\"><c r=\"A1\"><v>2</v></c><c r=\"B1\"><v>20</v></c></row><row r=\"2\"><c r=\"A2\"><v>1</v></c><c r=\"B2\"><v>10</v></c></row></sheetData></worksheet>"
        ])
    }

    @Test("actual style ID, paragraph alignment and complete numbering definitions stay on the named paragraph")
    func paragraphEdits() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("source.docx"), working = dir.appendingPathComponent("working.docx")
        try word(original); try FileManager.default.copyItem(at: original, to: working)
        let manifest = try OfficeExplicitTargets.read(url: original), target = manifest.paragraphs[1]
        #expect(manifest.paragraphStyles["ActualHeading"] == "Heading One")
        let commands: [OfficeExplicitCommand] = [.wordStyle(target, styleID: "ActualHeading"), .wordAlignment(target, .justified), .wordList(target, ordered: false)]
        for command in commands {
            let prepared = try OfficeExplicitPreparation.prepare(command, workingURL: working, sourceURL: original, baseSHA256: manifest.baseSHA256)
            #expect(prepared.engineCommands.isEmpty)
            try OfficeExplicitPreparation.verify(prepared.verification, url: working)
        }
        let snapshot = try OfficeOutputSnapshot.capture(url: working)
        #expect(snapshot.paragraphs[0].styleID == nil)
        #expect(snapshot.paragraphs[1].styleID == "ActualHeading")
        #expect(snapshot.paragraphs[1].alignment == "both")
        #expect(snapshot.numberingHasBullet)
        let archive = try OfficeArchive(url: working, maximumEntries: 4096)
        #expect(archive.paths.contains("word/numbering.xml"))
        #expect(try archive.xml(path: "word/_rels/document.xml.rels", limit: 100_000).contains("/numbering"))
        #expect(try FloeDigest.sha256Hex(ofFileAt: original) == manifest.baseSHA256)
    }

    @Test("stale digests and guessed styles cannot enter package preparation")
    func staleAndUnknownStyle() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.docx"); try word(source)
        let manifest = try OfficeExplicitTargets.read(url: source)
        var target = manifest.paragraphs[0]; target.baseSHA256 = String(repeating: "0", count: 64)
        #expect(throws: (any Error).self) { try OfficeExplicitTargets.validate(.wordAlignment(target, .left), sourceURL: source, baseSHA256: manifest.baseSHA256) }
        #expect(throws: (any Error).self) { try OfficeExplicitTargets.validate(.wordStyle(manifest.paragraphs[0], styleID: "Heading 1"), sourceURL: source, baseSHA256: manifest.baseSHA256) }
    }

    @Test("actual worksheet relationship order selects the exact native part before GoToCell")
    func worksheetOrderAndCodec() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.xlsx"); try workbook(source)
        let manifest = try OfficeExplicitTargets.read(url: source)
        #expect(manifest.sheets[0].member == "xl/worksheets/sheet9.xml")
        let target = manifest.sheets[1]
        let command = OfficeEngineCommand.explicit(.excelSort(target, range: "A1:B2", ascending: true))
        #expect(!command.requiresSelectionFingerprint)
        #expect(command.plan.steps.first == .selectPart(1))
        #expect(command.plan.steps[1] == .uno(name: ".uno:GoToCell", arguments: ["ToPoint": .string("A1:B2")]))
        #expect(try OfficeCommandCodec.decode(OfficeCommandCodec.encode([command])) == [command])
        #expect(OfficeEngineCommand.excelSort(ascending: true, range: "A1:B2").requiresSelectionFingerprint)
        var wrong = target; wrong.sheetIndex = 0
        #expect(throws: (any Error).self) { try OfficeExplicitTargets.validate(.excelSort(wrong, range: "A1:B2", ascending: true), sourceURL: source, baseSHA256: manifest.baseSHA256) }
    }

    @Test("sort output must contain the complete sorted rows on that sheet")
    func sortPersistedEvidence() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.xlsx"), working = dir.appendingPathComponent("working.xlsx")
        try workbook(source); try FileManager.default.copyItem(at: source, to: working)
        let manifest = try OfficeExplicitTargets.read(url: source)
        let prepared = try OfficeExplicitPreparation.prepare(.excelSort(manifest.sheets[1], range: "A1:B2", ascending: true), workingURL: working, sourceURL: source, baseSHA256: manifest.baseSHA256)
        #expect(throws: (any Error).self) { try OfficeExplicitPreparation.verify(prepared.verification, url: working) }
        let package = try OfficeArchive(url: working, maximumEntries: 4096)
        let member = "xl/worksheets/sheet1.xml"
        let xml = try package.xml(path: member, limit: 100_000).replacingOccurrences(of: "<v>2</v>", with: "<v>1</v>").replacingOccurrences(of: "<v>20</v>", with: "<v>10</v>")
        // Deliberately duplicates the first row: changing the target package
        // alone cannot satisfy the expected full-row permutation.
        try package.writeCopy(to: working, replacements: [member: Data(xml.utf8)], maximumMemberBytes: 100_000, maximumTotalBytes: 1_000_000, verify: { _ in })
        #expect(throws: (any Error).self) { try OfficeExplicitPreparation.verify(prepared.verification, url: working) }
    }

    @Test("read target pages expose their complete counts and immutable source revision")
    func targetPagination() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.docx"); try word(source, count: 205)
        let all = try OfficeExplicitTargets.read(url: source), first = try all.page(offset: 0), middle = try all.page(offset: 100), next = try all.page(offset: 200)
        #expect(first.paragraphs.count == 100 && first.paragraphCount == 205 && first.hasMore)
        #expect(first.nextOffset == 100)
        #expect(middle.paragraphs.count == 100 && middle.nextOffset == 200)
        #expect(next.paragraphs.count == 5 && !next.hasMore)
        #expect(next.baseSHA256 == first.baseSHA256)
        #expect(next.paragraphs.first?.paragraphIndex == 200)
    }

    @Test("PPT exact shape IDs align only named simple geometry and expose bounded read descriptions")
    func shapeAlignment() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.pptx"), working = dir.appendingPathComponent("working.pptx")
        let p = OfficeXMLNamespace.presentation, a = OfficeXMLNamespace.drawing
        func shape(_ id: Int, x: Int, y: Int, rotated: Bool = false) -> String {
            "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"Shape \(id)\"/></p:nvSpPr><p:spPr><a:xfrm\(rotated ? " rot=\"60000\"" : "")><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"50\" cy=\"40\"/></a:xfrm></p:spPr><p:txBody><a:p><a:r><a:t>Text \(id)</a:t></a:r></a:p></p:txBody></p:sp>"
        }
        try package(source, ["ppt/slides/slide4.xml": "<p:sld xmlns:p=\"\(p)\" xmlns:a=\"\(a)\"><p:cSld><p:spTree>" + shape(2, x: 100, y: 50) + shape(8, x: 200, y: 100) + shape(11, x: 300, y: 150) + shape(20, x: 400, y: 200, rotated: true) + "</p:spTree></p:cSld></p:sld>"])
        try FileManager.default.copyItem(at: source, to: working)
        let manifest = try OfficeExplicitTargets.read(url: source)
        #expect(manifest.shapeDescriptions["ppt/slides/slide4.xml"]?["8"]?.text == "Text 8")
        #expect(manifest.shapeDescriptions["ppt/slides/slide4.xml"]?["8"]?.x == 200)
        var target = manifest.slides[0]; target.shapeIDs = ["2", "8"]
        let prepared = try OfficeExplicitPreparation.prepare(.pptAlign(target, .left), workingURL: working, sourceURL: source, baseSHA256: manifest.baseSHA256)
        try OfficeExplicitPreparation.verify(prepared.verification, url: working)
        let after = try OfficeExplicitTargets.read(url: working)
        #expect(after.shapeDescriptions[target.member]?["8"]?.x == 100)
        #expect(after.shapeDescriptions[target.member]?["11"]?.x == 300)
        target.shapeIDs = ["2", "20"]
        #expect(throws: (any Error).self) { try OfficeExplicitTargets.validate(.pptAlign(target, .left), sourceURL: source, baseSHA256: manifest.baseSHA256) }
    }

    @Test("one read page contains at most 100 shape descriptions even for a large slide")
    func shapeDescriptionPagination() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.pptx")
        let p = OfficeXMLNamespace.presentation, a = OfficeXMLNamespace.drawing
        let shapes = (1...151).map { i in "<p:sp><p:nvSpPr><p:cNvPr id=\"\(i)\" name=\"Object \(i)\"/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"100\" y=\"100\"/><a:ext cx=\"50\" cy=\"40\"/></a:xfrm></p:spPr></p:sp>" }.joined()
        try package(source, ["ppt/slides/slide1.xml": "<p:sld xmlns:p=\"\(p)\" xmlns:a=\"\(a)\"><p:cSld><p:spTree>\(shapes)</p:spTree></p:cSld></p:sld>"])
        let manifest = try OfficeExplicitTargets.read(url: source), first = try manifest.page(offset: 0), second = try manifest.page(offset: 100)
        #expect(first.shapeDescriptions.values.reduce(0) { $0 + $1.count } == 100)
        #expect(second.shapeDescriptions.values.reduce(0) { $0 + $1.count } == 51)
        #expect(first.slideTargetCount == 151 && first.hasMore && first.nextOffset == 100)
        #expect(second.baseSHA256 == first.baseSHA256 && !second.hasMore)
    }

    @Test("bounded XML refuses DTDs and roundtrips escaped text with namespace aliases")
    func boundedXML() throws {
        #expect(throws: (any Error).self) { try OfficeXMLNode.parse("<!DOCTYPE x [<!ENTITY a SYSTEM 'file:///x'>]><x>&a;</x>") }
        let node = try OfficeXMLNode.parse("<z:document xmlns:z=\"\(OfficeXMLNamespace.word)\"><z:p><z:r><z:t>&lt;a&amp;b&gt;</z:t></z:r></z:p></z:document>")
        #expect(node.descendants("t", OfficeXMLNamespace.word).first?.text == "<a&b>")
        #expect(try OfficeXMLNode.parse(node.xml).descendants("p", OfficeXMLNamespace.word).count == 1)
    }

    @Test("ordered exact edits save and close distinct sessions; a failed close retains staging")
    func orderedLifecycle() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.docx"); try word(source)
        let manifest = try OfficeExplicitTargets.read(url: source), target = manifest.paragraphs[1]
        let commands: [OfficeEngineCommand] = [.explicit(.wordStyle(target, styleID: "ActualHeading")), .explicit(.wordAlignment(target, .right))]
        let proposal = OfficeCommandProposal(documentID: "source.docx", format: "docx", baseSHA256: manifest.baseSHA256, summary: "Exact paragraphs", commandsJSON: try OfficeCommandCodec.encode(commands), expectations: OfficeCommandCodec.expectations(commands))
        let run = UUID(), task = UUID()
        let binding = RuntimeAuthorityBinding(runID: run, taskID: task, environmentBinding: "test", canonicalTarget: "file:" + source.resolvingSymlinksInPath().path, toolName: "document.office.edit", operation: "apply", operationID: "exact", idempotencyKey: "exact", baseRevision: manifest.baseSHA256, payloadDigest: String(repeating: "a", count: 64))
        let auth = OfficeAutomaticAuthorization(runID: run, taskID: task, operationID: "exact", idempotencyKey: "exact", approvalGrantID: UUID(), binding: binding)
        let access = OfficeCommandAccess(environmentID: nil, workspacePath: dir.path, ownerKind: "chat", ownerID: task, conversationID: task)
        let factory = FakeServiceSessionFactory { _ in }
        let receipt = try await OfficeAutomaticExecutor(factory: factory).execute(proposal: proposal, authorization: auth, relativeOutput: "edited.docx", requestID: "exact", access: access)
        #expect(receipt.saved && receipt.sourceUnchanged)
        #expect(await factory.openCount == 2)
        let sessions = await factory.sessions
        #expect(sessions.allSatisfy { $0.saved && $0.closed && $0.appliedCommands.isEmpty })
        #expect(try FloeDigest.sha256Hex(ofFileAt: source) == manifest.baseSHA256)

        let bad = FakeServiceSessionFactory(closeError: FloeError.validationFailed("close not acknowledged")) { _ in }
        await #expect(throws: (any Error).self) {
            try await OfficeAutomaticExecutor(factory: bad).execute(proposal: proposal, authorization: auth, relativeOutput: "failed.docx", requestID: "bad", access: access)
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("failed.docx").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".floe-automation/\(proposal.id)/working.docx").path))
    }
}
