#if canImport(UIKit)
import Foundation
import Testing
import UIKit
import PDFKit
import FloeSkills
import FloePersistence
import FloeTools
import FloeWorkspace
import CryptoKit
@testable import FloeApp

@Suite("FloeApp.SkillLifecycle", .serialized)
struct SkillLifecycleTests {
    @Test("Task deletion retains failed cleanup and replays without touching a symlink target")
    @MainActor func durablePrivateCleanup() async throws {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let conversation = try await environment.conversationCenter.createConversation(title: "Delete safely")
        let center = environment.workspaceCenter
        try await center.openTaskWorkspace(conversationID: conversation.id)
        let root = try #require(center.currentRootURL)
        let workspaceID = try #require(center.currentWorkspace?.id)
        center.closeCurrentWorkspace()
        let saved = root.deletingLastPathComponent().appendingPathComponent("saved-\(UUID())")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("keep-\(UUID())")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appendingPathComponent("keep.txt"))
        try FileManager.default.moveItem(at: root, to: saved)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: saved)
            try? FileManager.default.removeItem(at: outside)
        }
        await #expect(throws: (any Error).self) {
            try await environment.conversationCenter.deleteConversation(id: conversation.id)
        }
        let store = SQLiteWorkspaceStore(database: environment.database)
        #expect(try await environment.conversationStore.conversation(id: conversation.id) == nil)
        #expect(!environment.conversationCenter.conversations.contains(where: { $0.id == conversation.id }))
        #expect(try await store.pendingLocalCleanup().contains(where: { $0.workspaceID == workspaceID }))
        #expect(try String(contentsOf: outside.appendingPathComponent("keep.txt"), encoding: .utf8) == "keep")
        try FileManager.default.removeItem(at: root)
        try FileManager.default.moveItem(at: saved, to: root)
        #expect(await center.retryPendingLocalCleanup().isEmpty)
        #expect(try await store.pendingLocalCleanup().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(try await store.workspace(id: workspaceID) == nil)
    }

    @Test("Workspace manager keeps the task root unchanged and reports batch failures")
    @MainActor func isolatedWorkspaceManagement() async throws {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let first = try await environment.conversationCenter.createConversation(title: "Active task")
        let second = try await environment.conversationCenter.createConversation(title: "Managed task")
        let primary = environment.workspaceCenter
        let browser = WorkspaceCenter(environment: environment, publishesSharedState: false)
        try await primary.openTaskWorkspace(conversationID: first.id)
        let activeRoot = try #require(primary.currentRootURL)
        try await browser.openTaskWorkspace(conversationID: second.id)
        let managedRoot = try #require(browser.currentRootURL)
        defer {
            browser.closeCurrentWorkspace()
            primary.closeCurrentWorkspace()
            try? FileManager.default.removeItem(at: activeRoot)
            try? FileManager.default.removeItem(at: managedRoot)
        }
        #expect(WorkspaceCenter.toolRootProvider() == activeRoot)
        try Data("keep".utf8).write(to: activeRoot.appendingPathComponent("keep.txt"))
        try Data("move".utf8).write(to: managedRoot.appendingPathComponent("move.txt"))
        try browser.createDirectory(relativePath: "folder")
        let tree = FileTreeViewModel(center: browser)
        try await tree.move(.init(relativePath: "move.txt", name: "move.txt", isDirectory: false, size: 4), to: "folder/moved.txt")
        #expect(FileManager.default.fileExists(atPath: managedRoot.appendingPathComponent("folder/moved.txt").path))
        let failures = await tree.deleteBatch(["folder", "folder/moved.txt", "../outside"])
        #expect(Set(failures.keys) == ["../outside"])
        #expect(!FileManager.default.fileExists(atPath: managedRoot.appendingPathComponent("folder").path))
        #expect(try String(contentsOf: activeRoot.appendingPathComponent("keep.txt"), encoding: .utf8) == "keep")
        browser.closeCurrentWorkspace()
        #expect(WorkspaceCenter.toolRootProvider() == activeRoot)
    }

    @Test("Inline PDF session reloads modified documents and surfaces corrupt content")
    @MainActor func inlinePDFReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-reader-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("reader.pdf")
        try pdfFixture().write(to: url)
        let session = PDFReadingSession()
        await session.load(url)
        #expect(session.document?.pageCount == 1)
        #expect(session.error == nil)
        let replacement = try #require(PDFDocument(data: pdfFixture()))
        replacement.insert(try #require(PDFDocument(data: pdfFixture())?.page(at: 0)), at: 1)
        try #require(replacement.dataRepresentation()).write(to: url, options: .atomic)
        await session.load(url)
        #expect(session.document?.pageCount == 2)
        try Data("not a PDF".utf8).write(to: url, options: .atomic)
        await session.load(url)
        #expect(session.error != nil)
    }

    @Test("PDF export preserves real text and PNG output without overwriting")
    @MainActor func pdfExports() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-export-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try pdfFixture().write(to: root.appendingPathComponent("input.pdf"))
        let context = ToolContext(runID: UUID(), approvalGrantID: UUID(), workspaceRootURL: root, cancellation: CancellationToken())
        let args = PDFExportTool.Arguments(inputPath: "input.pdf", outputPath: "text.json", format: "json")
        _ = try await PDFExportTool().execute(args, context: context)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("text.json"))) as? [String: Any])
        let pages = try #require(json["pages"] as? [[String: Any]])
        #expect(pages.first?["page"] as? Int == 1)
        #expect((pages.first?["text"] as? String)?.contains("HELLO") == true)
        await #expect(throws: (any Error).self) { try await PDFExportTool().execute(args, context: context) }
        _ = try await PDFRenderTool().execute(.init(path: "input.pdf", page: 1, outputPath: "preview.png", format: "png"), context: context)
        let png = try Data(contentsOf: root.appendingPathComponent("preview.png"))
        #expect(png.prefix(8) == Data([137,80,78,71,13,10,26,10]))
        #expect(UIImage(data: png) != nil)
    }

    @Test("Encrypted PDF unlock uses approved credential references and preserves its source")
    @MainActor func encryptedPDFUnlock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-unlock-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = try #require(PDFDocument(data: pdfFixture()))
        let encrypted = try #require(pdf.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "fixture-user", PDFDocumentWriteOption.ownerPasswordOption: "fixture-owner"]))
        try encrypted.write(to: root.appendingPathComponent("locked.pdf"))
        let id = UUID()
        let args = PDFUnlockTool.Arguments(inputPath: "locked.pdf", outputPath: "open.pdf", passwordRef: "⟨credential:\(id.uuidString)⟩")
        let context = ToolContext(runID: UUID(), approvalGrantID: UUID(), workspaceRootURL: root, cancellation: CancellationToken())
        let tool = PDFUnlockTool { requestedID in
            #expect(requestedID == id)
            return Data("fixture-owner".utf8)
        }
        let unapproved = ToolContext(runID: UUID(), workspaceRootURL: root, cancellation: CancellationToken())
        await #expect(throws: (any Error).self) { try await tool.execute(args, context: unapproved) }
        let wrong = PDFUnlockTool { _ in Data("wrong-fixture".utf8) }
        await #expect(throws: (any Error).self) { try await wrong.execute(args, context: context) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("open.pdf").path))
        _ = try await tool.execute(args, context: context)
        let reopened = try #require(PDFDocument(url: root.appendingPathComponent("open.pdf")))
        #expect(!reopened.isLocked)
        #expect(reopened.string?.contains("HELLO") == true)
        #expect(try Data(contentsOf: root.appendingPathComponent("locked.pdf")) == encrypted)
        await #expect(throws: (any Error).self) { try await tool.execute(args, context: context) }
    }

    @Test("Native PDF annotation, form, metadata and page workflows round-trip")
    @MainActor func advancedPDFWorkflows() async throws {
        let input = pdfFixture()
        let actions = Data(#"""
        [
          {"action":"addAnnotation","page":1,"kind":"freeText","bounds":[10,10,120,30],"text":"Comment"},
          {"action":"createField","page":1,"kind":"text","fieldName":"name","bounds":[10,50,120,30],"text":"Before"},
          {"action":"setField","fieldName":"name","text":"After"},
          {"action":"setMetadata","metadata":{"title":"Test title","author":"Floe"}},
          {"action":"insertBlankPage","page":2,"bounds":[0,0,300,200]},
          {"action":"setBookmarks","bookmarks":[{"title":"Start","page":1}]}
        ]
        """#.utf8)
        let result = try await PDFDocumentOperations.run(input,
            operations: JSONDecoder().decode([PDFDocumentOperations.Operation].self, from: actions), cancellation: CancellationToken())
        let pdf = try #require(PDFDocument(data: result.data))
        #expect(pdf.pageCount == 2)
        #expect(pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Test title")
        #expect(pdf.page(at: 0)?.annotations.contains { $0.contents == "Comment" } == true)
        #expect(pdf.page(at: 0)?.annotations.first { $0.fieldName == "name" }?.widgetStringValue == "After")
        #expect(pdf.outlineRoot?.child(at: 0)?.label == "Start")
        let selectedInventory = try #require(JSONSerialization.jsonObject(with: FloePDFiumBridge.inspect(result.data, pages: [NSNumber(value: 2)])) as? [String: Any])
        let selectedPages = try #require(selectedInventory["pages"] as? [[String: Any]])
        #expect(selectedPages.count == 1)
        #expect(selectedPages.first?["page"] as? Int == 2)
        let flatten = Data(#"[{"action":"flattenAnnotations","acceptFlattening":true}]"#.utf8)
        let flattened = try await PDFDocumentOperations.run(result.data,
            operations: JSONDecoder().decode([PDFDocumentOperations.Operation].self, from: flatten), cancellation: CancellationToken())
        let flattenedPDF = try #require(PDFDocument(data: flattened.data))
        #expect(flattenedPDF.page(at: 0)?.annotations.isEmpty == true)
        #expect(flattenedPDF.string?.contains("HELLO") == true)
        let removal = Data(#"[{"action":"removeField","fieldName":"name"},{"action":"removeAnnotation","page":1,"annotationIndex":0},{"action":"reorderPages","pages":[2,1]}]"#.utf8)
        let removed = try await PDFDocumentOperations.run(result.data,
            operations: JSONDecoder().decode([PDFDocumentOperations.Operation].self, from: removal), cancellation: CancellationToken())
        #expect(PDFDocument(data: removed.data)?.page(at: 1)?.annotations.isEmpty == true)
        #expect(try PDFToolSupport.pageNumbers(from: "2,1", pageCount: 2) == [2,1])
        let schema = try JSONSerialization.jsonObject(with: Data(PDFEditTool.parametersJSON.utf8)) as? [String: Any]
        #expect((schema?["properties"] as? [String: Any])?["operations"] != nil)
    }

    @Test("Raster redaction requires consent and removes original text and annotations")
    @MainActor func rasterRedaction() async throws {
        let input = pdfFixture()
        let json = Data(#"[{"action":"rasterRedact","acceptRasterization":true,"regions":[{"page":1,"bounds":[0,0,300,200]}]}]"#.utf8)
        let operations = try JSONDecoder().decode([PDFDocumentOperations.Operation].self, from: json)
        let result = try await PDFDocumentOperations.run(input, operations: operations, cancellation: CancellationToken())
        #expect(result.evidence.contains("verifiedImageOnly=true"))
        let pdf = try #require(PDFDocument(data: result.data))
        #expect((pdf.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(pdf.page(at: 0)?.annotations.isEmpty == true)
        var denied = operations; denied[0].acceptRasterization = false
        await #expect(throws: (any Error).self) {
            try await PDFDocumentOperations.run(input, operations: denied, cancellation: CancellationToken())
        }
    }

    @Test("Region replacement reflows searchable text without retaining covered text")
    @MainActor func regionTextReplacement() async throws {
        let actions = Data(#"[{"action":"replaceRegion","page":1,"bounds":[0,0,300,200],"expectedObjectCount":1,"text":"Replacement text across several lines with Unicode: 中文","fontSize":18}]"#.utf8)
        let result = try await PDFDocumentOperations.run(pdfFixture(),
            operations: JSONDecoder().decode([PDFDocumentOperations.Operation].self, from: actions), cancellation: CancellationToken())
        let text = PDFDocument(data: result.data)?.string ?? ""
        #expect(!text.contains("HELLO"))
        #expect(text.contains("Replacement"))
        #expect(text.contains("中文"))
        #expect(!text.contains("\u{2F42}"))

        // A following native operation must reuse the verified bytes rather
        // than make PDFKit regenerate the preceding text's Unicode mapping.
        let second = Data(#"[{"action":"addText","page":1,"bounds":[0,0,300,60],"text":"Second native operation","fontSize":12}]"#.utf8)
        let chained = try await PDFDocumentOperations.run(result.data,
            operations: JSONDecoder().decode([PDFDocumentOperations.Operation].self, from: second), cancellation: CancellationToken())
        let reopened = try #require(PDFDocument(data: chained.data))
        #expect(reopened.string?.contains("中文") == true)
        #expect(reopened.string?.contains("Second native operation") == true)

        // The final-file guard must reject lost text, not merely accept a
        // successfully reopened PDF or a visually equivalent glyph.
        #expect(throws: (any Error).self) {
            try PDFDocumentOperations.verifySavedText(["中文"], in: PDFDocument(data: pdfFixture())!)
        }
    }

    @Test("On-device OCR adds searchable text to a raster-only PDF")
    @MainActor func searchablePDFOCR() async throws {
        let json = Data(#"[{"action":"searchableOCR","acceptRasterization":true,"languages":["en-US"]}]"#.utf8)
        let result = try await PDFDocumentOperations.run(pdfFixture(),
            operations: JSONDecoder().decode([PDFDocumentOperations.Operation].self, from: json), cancellation: CancellationToken())
        #expect(PDFDocument(data: result.data)?.string?.uppercased().contains("HELLO") == true)
    }

    @Test("Native PDF image insert, replacement and removal form a complete workflow")
    @MainActor func pdfImageWorkflow() async throws {
        let pixels = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 20)).image { c in
            UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        }
        let images = ["test.png": try #require(pixels.pngData())]
        let insert = Data(#"[{"action":"insertImage","page":1,"bounds":[20,20,100,50],"imagePath":"test.png"}]"#.utf8)
        let first = try await PDFDocumentOperations.run(pdfFixture(), operations: JSONDecoder().decode([PDFDocumentOperations.Operation].self, from: insert), images: images, cancellation: CancellationToken())
        let replace = Data(#"[{"action":"replaceImage","page":1,"bounds":[20,20,100,50],"imagePath":"test.png","expectedObjectCount":1}]"#.utf8)
        let second = try await PDFDocumentOperations.run(first.data, operations: JSONDecoder().decode([PDFDocumentOperations.Operation].self, from: replace), images: images, cancellation: CancellationToken())
        let remove = Data(#"[{"action":"removeImage","page":1,"bounds":[20,20,100,50],"expectedObjectCount":1}]"#.utf8)
        let third = try await PDFDocumentOperations.run(second.data, operations: JSONDecoder().decode([PDFDocumentOperations.Operation].self, from: remove), cancellation: CancellationToken())
        let inventory = try #require(try JSONSerialization.jsonObject(with: FloePDFiumBridge.inspect(third.data)) as? [String: Any])
        let pages = try #require(inventory["pages"] as? [[String: Any]])
        let objects = try #require(pages.first?["objects"] as? [[String: Any]])
        #expect(!objects.contains { $0["contentType"] as? String == "image" })
        #expect(PDFDocument(data: third.data)?.string?.contains("HELLO") == true)
    }

    @Test("PDF edit enforces revision and new-output boundaries")
    @MainActor func pdfEditRevisionAndOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-edit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = pdfFixture(); try input.write(to: root.appendingPathComponent("input.pdf"))
        let sha = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        let json: [String: Any] = ["inputPath": "input.pdf", "outputPath": "output.pdf", "expectedSHA256": sha,
            "operations": [["action": "setMetadata", "metadata": ["title": "Verified"]]]]
        let args = try JSONDecoder().decode(PDFEditTool.Arguments.self, from: JSONSerialization.data(withJSONObject: json))
        let context = ToolContext(runID: UUID(), approvalGrantID: UUID(), workspaceRootURL: root, cancellation: CancellationToken())
        _ = try await PDFEditTool().execute(args, context: context)
        await #expect(throws: (any Error).self) { try await PDFEditTool().execute(args, context: context) }
        var stale = args; stale.outputPath = "stale.pdf"; stale.expectedSHA256 = String(repeating: "0", count: 64)
        await #expect(throws: (any Error).self) { try await PDFEditTool().execute(stale, context: context) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("stale.pdf").path))
        #expect(try Data(contentsOf: root.appendingPathComponent("input.pdf")) == input)
    }

    @MainActor private func pdfFixture() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 200)).pdfData { context in
            context.beginPage()
            ("HELLO TEST" as NSString).draw(at: CGPoint(x: 30, y: 100), withAttributes: [.font: UIFont.systemFont(ofSize: 26)])
        }
    }

    @Test("Native RAR5 extraction verifies bytes and never overwrites output")
    func nativeRARExtraction() async throws {
        // BSD libarchive 3.8.9 test_read_format_rar5_stored.rar fixture.
        let bytes = try #require(Data(base64Encoded: "UmFyIRoHAQAzkrXlCgEFBgAFAQGAgAA4MAZjLAIDC50ABJ0ApIMCtEOglYAAAQ5oZWxsb3dvcmxkLnR4dAoDE34Oq1tW6Q4aaGVsbG8gbGliYXJjaGl2ZSB0ZXN0IHN1aXRlIQodd1ZRAwUEAA=="))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rar-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try bytes.write(to: root.appendingPathComponent("input.rar"))
        let request = ArchiveCompressedRequest(action: "extract", format: "rar", source: "input.rar", destination: "out", workspaceRoot: root)
        let result = try await RARArchiveService.run(request)
        #expect(result.contains("\"status\":\"ok\""))
        #expect(try String(contentsOf: root.appendingPathComponent("out/helloworld.txt"), encoding: .utf8) == "hello libarchive test suite!\n")
        await #expect(throws: (any Error).self) { try await RARArchiveService.run(request) }
        try bytes.dropLast(20).write(to: root.appendingPathComponent("broken.rar"))
        await #expect(throws: (any Error).self) {
            try await RARArchiveService.run(.init(action: "extract", format: "rar", source: "broken.rar", destination: "broken", workspaceRoot: root))
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("broken").path))
    }

    @Test("RAR compressed payloads round-trip; links, encryption and incomplete volumes fail atomically")
    func rarDecoderBoundaries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rar-boundaries-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, item) in RARFixtures.encoded.sorted(by: { $0.key < $1.key }).enumerated() {
            let bytes = try #require(Data(base64Encoded: item.value))
            try bytes.write(to: root.appendingPathComponent(item.key))
            let destination = "out-\(index)"
            let request = ArchiveCompressedRequest(action: "extract", format: "rar", source: item.key, destination: destination, workspaceRoot: root)
            if item.key == "test_read_format_rar5_compressed.rar" {
                _ = try await RARArchiveService.run(request)
                let result = try Data(contentsOf: root.appendingPathComponent(destination + "/test.bin"))
                #expect(result.count == 1200)
                let expected = (1...300).flatMap { k -> [UInt8] in
                    let value = UInt32(max(0, k * k - 3 * k + 1))
                    return [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)]
                }
                #expect(result == Data(expected))
            } else if item.key == "test_read_format_rar_windows.rar" {
                _ = try await RARArchiveService.run(request)
                #expect(try String(contentsOf: root.appendingPathComponent(destination + "/test.txt"), encoding: .utf8) == "test text file\r\n")
            } else {
                await #expect(throws: (any Error).self) { try await RARArchiveService.run(request) }
                #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(destination).path))
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".floe-rar-") })
    }

    @Test("Native PDF text replacement removes the old text instead of covering it")
    @MainActor func nativePDFContentReplacement() async throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 200))
        let input = renderer.pdfData { context in
            context.beginPage()
            ("Hello" as NSString).draw(at: CGPoint(x: 30, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        let result = try await PDFContentEditor.replace(in: input,
            rulesJSON: Data(#"[{"find":"Hello","replace":"He"}]"#.utf8), cancellation: CancellationToken())
        let document = try #require(PDFDocument(data: result.data))
        #expect(result.replacements == 1)
        #expect(document.string?.contains("He") == true)
        #expect(document.string?.contains("Hello") == false)
        #expect(document.page(at: 0)?.annotations.isEmpty == true)
        let cancelled = CancellationToken()
        cancelled.cancel()
        await #expect(throws: (any Error).self) {
            try await PDFContentEditor.replace(in: input,
                rulesJSON: Data(#"[{"find":"Hello","replace":"He"}]"#.utf8), cancellation: cancelled)
        }
        await #expect(throws: (any Error).self) {
            try await PDFContentEditor.replace(in: input,
                rulesJSON: Data(#"[{"find":"Missing","replace":"He"}]"#.utf8), cancellation: CancellationToken())
        }
    }

    @Test(arguments: ["prepared", "rollingBack"]) @MainActor func interruptedUpgradeRestoresFilesBeforeServingSkills(phase: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-recover-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let center = SkillsCenter(environment: environment, installationRoot: root)
        let created = try await center.createSkill(.init(name: "Recover Test", description: "Fixture", instructions: "Original"))
        let old = try #require(try await environment.skillStore.all().first { $0.id == created.id })
        let history = root.appendingPathComponent(".upgrade-history/\(UUID())")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent(old.id), to: history.appendingPathComponent("previous"))
        let oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old))
        let journal: [String: Any] = ["oldSkill": oldJSON, "oldGrants": [], "newDigest": String(repeating: "a", count: 64),
            "source": ["owner": "o", "repository": "r", "ref": "main", "path": "SKILL.md"], "commit": String(repeating: "b", count: 40),
            "phase": phase, "createdAt": Date().timeIntervalSinceReferenceDate]
        try JSONSerialization.data(withJSONObject: journal).write(to: history.appendingPathComponent("transaction.json"))
        try Data("interrupted replacement".utf8).write(to: root.appendingPathComponent("\(old.id)/SKILL.md"))
        let relaunched = SkillsCenter(environment: environment, installationRoot: root)
        await relaunched.load()
        #expect(relaunched.errorMessage == nil)
        #expect(try SkillPackageValidator().validate(packageAt: root.appendingPathComponent(old.id)).canonicalSHA256 == old.rewrittenDigest)
        #expect(try await relaunched.readSkills(id: old.id).first?.digest == old.rewrittenDigest)
    }

    @Test @MainActor func reviewedUpgradeRollbackAndRunningVersionPin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-upgrade-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let install = root.appendingPathComponent("Skills")
        let center = SkillsCenter(environment: environment, installationRoot: install)
        let created = try await center.createSkill(.init(name: "Upgrade Test", description: "Fixture", instructions: "Original"))
        let initial = try #require(try await center.readSkills(id: created.id).first)
        let runID = UUID()
        try await environment.skillStore.setPermission(skillID: created.id, capability: "workspace.read", decision: "allow",
            scopeJSON: #"{"path":"reports"}"#, expiresAt: Date().addingTimeInterval(60))
        try await environment.skillStore.setPermission(skillID: created.id, capability: "network", decision: "deny")
        let originalPermissions = try await environment.skillStore.permissions(skillID: created.id)
        _ = await center.runtimeSelection(runID: runID)
        let current = try SkillContentSnapshot(root: install.appendingPathComponent(created.id), expectedDigest: initial.digest)
        let proposedRoot = root.appendingPathComponent("proposed")
        try FileManager.default.copyItem(at: current.package.rootURL, to: proposedRoot)
        try (current.files["SKILL.md"]! + Data("\nNew reviewed instructions\n".utf8)).write(to: proposedRoot.appendingPathComponent("SKILL.md"))
        let proposed = try SkillPackageValidator().validate(packageAt: proposedRoot)
        let source = try GitHubSkillSource(owner: "floe", repository: "guides", ref: "main", path: "SKILL.md")
        let candidate = try SkillUpgradeCandidate(source: source, commit: String(repeating: "a", count: 40), installed: current,
            proposed: SkillContentSnapshot(root: proposedRoot, expectedDigest: proposed.canonicalSHA256))
        try await center.stageUpgradeForReview(candidate, at: proposedRoot)
        await center.applyReviewedUpgrade()
        #expect(center.errorMessage == nil)
        #expect(try await center.readSkills(id: created.id).first?.digest == proposed.canonicalSHA256)
        #expect(try await center.readSkills(id: created.id, runID: runID).first?.digest == initial.digest)
        #expect(try await center.readSkills(id: created.id, runID: runID).first?.currentDigest == proposed.canonicalSHA256)
        // A new coordinator simulates process relaunch; task snapshots persist.
        let relaunched = SkillsCenter(environment: environment, installationRoot: install)
        #expect(try await relaunched.readSkills(id: created.id, runID: runID).first?.digest == initial.digest)
        let updated = try #require(try await environment.skillStore.all().first { $0.id == created.id })
        await center.rollbackLatestUpgrade(skill: updated)
        #expect(center.errorMessage == nil)
        #expect(try await center.readSkills(id: created.id).first?.digest == initial.digest)
        #expect(try await environment.skillStore.permissions(skillID: created.id) == originalPermissions)
    }

    @Test @MainActor func createReadUpdateDisableRemovePreservesPackageAndConflicts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-lifecycle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let center = SkillsCenter(environment: environment, installationRoot: root.appendingPathComponent("Skills"))
        let created = try await center.createSkill(.init(name: "Lifecycle Test", description: "Use for fixture testing", instructions: "Original instructions"))
        let initial = try #require(try await center.readSkills(id: created.id).first)
        let manifest = try Data(contentsOf: root.appendingPathComponent("Skills/\(created.id)/floe.json"))
        _ = try await center.manageSkill(.init(action: .update, id: created.id, expectedDigest: initial.digest, instructions: "Updated instructions"))
        let updated = try #require(try await center.readSkills(id: created.id).first)
        #expect(updated.digest != initial.digest)
        #expect(updated.markdown?.contains("Updated instructions") == true)
        #expect(try Data(contentsOf: root.appendingPathComponent("Skills/\(created.id)/floe.json")) == manifest)
        await #expect(throws: SkillStoreConflict.self) {
            try await center.manageSkill(.init(action: .remove, id: created.id, expectedDigest: initial.digest))
        }
        _ = try await center.manageSkill(.init(action: .setEnabled, id: created.id, expectedDigest: updated.digest, enabled: false))
        #expect(try await center.readSkills(id: created.id).first?.enabled == false)
        let removed = try await center.manageSkill(.init(action: .remove, id: created.id, expectedDigest: updated.digest))
        #expect(removed.contains("recoverablePackage="))
        #expect(try await center.readSkills(id: nil).allSatisfy { $0.id != created.id })
        let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("RemovedSkills"), includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: backups[0].appendingPathComponent("floe.json")) == manifest)
    }

    @Test @MainActor func firstReadSeedsGuidesAndKeepsPythonIndependent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skill-seed-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let center = SkillsCenter(environment: environment, installationRoot: root)
        let pdf = try #require(try await center.readSkills(id: "floe-pdf").first)
        #expect(pdf.digest == BundledDomainSkills.officialPackageDigests["floe-pdf"])
        #expect(pdf.requiredToolNames?.contains("document.pdf.inspect") == true)
        await #expect(throws: (any Error).self) {
            try await center.manageSkill(.init(action: .update, id: pdf.id, expectedDigest: pdf.digest, instructions: "Unsigned replacement"))
        }
        await #expect(throws: (any Error).self) {
            try await center.createSkill(.init(name: "floe-pdf", description: "Reserved identity", instructions: "Unsigned replacement"))
        }
        #expect(center.builtinSeedFailures.isEmpty)
        let catalogNames = Set(ToolCatalog.allDescriptors.map(\.name))
        for guide in BundledDomainSkills.all {
            #expect(Set(guide.toolNames).isSubset(of: catalogNames), "Unknown tool reference in \(guide.id): \(Set(guide.toolNames).subtracting(catalogNames))")
        }
        #expect(try await center.readSkills(id: nil).count == BundledDomainSkills.all.count)
        let selection = await center.runtimeSelection(runID: UUID())
        #expect(selection.allowedToolNames == nil)
        let python = try #require(try await center.readSkills(id: "floe-python").first)
        await #expect(throws: (any Error).self) {
            try await center.manageSkill(.init(action: .setEnabled, id: python.id, expectedDigest: python.digest, enabled: false))
        }
    }
}
#endif
