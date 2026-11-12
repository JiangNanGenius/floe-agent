// FloeWorkspaceTests — Real-execution behavior of the nine workspace file
// tools against a temporary directory, plus structured errors, output
// limits, conflict detection, patch all-or-nothing semantics, host-scope
// rejection and cancellation propagation.
// See docs/ARCHITECTURE_AGENT_WORKSPACE.md §6.

import Foundation
import Testing
@testable import FloeWorkspace
import FloeCore
import FloeModels
import FloeTools

@Suite("FloeWorkspace.FileTools")
struct FileToolsTests {

    // MARK: Fixture

    private final class Fixture: @unchecked Sendable {
        let root: URL
        let environment: WorkspaceToolEnvironment
        let context: ToolContext

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-tools-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            environment = WorkspaceToolEnvironment(rootProvider: { [root] in root })
            context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
            if let support = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false
            ) {
                try? FileManager.default.removeItem(at: support
                    .appendingPathComponent("FloeAgent/ChangeArtifacts", isDirectory: true)
                    .appendingPathComponent(context.runID.uuidString, isDirectory: true))
            }
        }

        func write(_ relative: String, _ content: String) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        }

        func writeData(_ relative: String, _ data: Data) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }

        func read(_ relative: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        }

        func readData(_ relative: String) throws -> Data {
            try Data(contentsOf: root.appendingPathComponent(relative))
        }

        func exists(_ relative: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
        }
    }

    private func makeFixture() throws -> Fixture { try Fixture() }

    /// First `key=value` token on the tool summary's header line.
    private func field(_ name: String, in summary: String) throws -> String {
        let header = summary.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let token = header.split(separator: " ").first { $0.hasPrefix(name + "=") }
        return String(try #require(token).dropFirst(name.count + 1))
    }

    /// Tool read output after its header line (the actual page text).
    private func pageBody(_ summary: String) throws -> String {
        let lines = summary.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        return lines.count == 2 ? String(lines[1]) : ""
    }

    // MARK: Registration

    @Test("Registration wires every workspace tool into catalog and registry")
    func registration() throws {
        let fixture = try makeFixture()
        let registry = ToolRunnerRegistry()
        registerWorkspaceTools(rootProvider: { fixture.root }, registry: registry)

        let expected = [
            "workspace.listDirectory", "workspace.readFile", "workspace.searchFiles",
            "workspace.inspectFileMetadata", "workspace.createFile", "workspace.writeFile",
            "workspace.applyPatch", "workspace.moveFile", "workspace.deleteFile",
            "workspace.createDirectory", "workspace.copyFile", "workspace.appendFile", "workspace.replaceText"
        ]
        let registeredNames = Set(registry.allDescriptors.map(\.name))
        let catalogNames = Set(ToolCatalog.allDescriptors.map(\.name))
        for name in expected {
            #expect(ToolCatalog.descriptor(named: name) != nil, "descriptor missing for \(name)")
            #expect(registry.runner(named: name) != nil, "runner missing for \(name)")
            #expect(registeredNames.contains(name), "model-facing runner descriptor missing for \(name)")
            #expect(catalogNames.contains(name), "model-facing catalog descriptor missing for \(name)")
        }
        let read = ToolCatalog.descriptor(named: "workspace.readFile")
        #expect(read?.isSideEffecting == false)
        #expect(read?.riskLabels == [.readsFiles])
        let delete = ToolCatalog.descriptor(named: "workspace.deleteFile")
        #expect(delete?.isSideEffecting == true)
        #expect(delete?.riskLabels == [.writesFiles, .deletesFiles])
    }

    @Test("Model-facing text contracts describe general plain text, not Markdown-only files")
    func generalTextContracts() {
        let create = ToolCatalog.descriptor(named: "workspace.createFile")
        #expect(create?.toolDescription.contains("Prefer the .md extension") == false)
        for phrase in ["plain-text", "source code", "scripts", "LaTeX", "extensionless"] {
            #expect(create?.toolDescription.localizedCaseInsensitiveContains(phrase) == true,
                    "createFile contract is missing \(phrase)")
        }
        let read = ToolCatalog.descriptor(named: "workspace.readFile")
        #expect(read?.toolDescription.localizedCaseInsensitiveContains("extensionless") == true)
        let write = ToolCatalog.descriptor(named: "workspace.writeFile")
        #expect(write?.toolDescription.localizedCaseInsensitiveContains("source code") == true)
        let append = ToolCatalog.descriptor(named: "workspace.appendFile")
        #expect(append?.toolDescription.localizedCaseInsensitiveContains("unknown-extension") == true)
        let replace = ToolCatalog.descriptor(named: "workspace.replaceText")
        #expect(replace?.toolDescription.localizedCaseInsensitiveContains("unknown-extension") == true)
        let patch = ToolCatalog.descriptor(named: "workspace.applyPatch")
        #expect(patch?.toolDescription.localizedCaseInsensitiveContains("plain-text") == true)
    }

    // MARK: listDirectory

    @Test("listDirectory returns entries sorted dirs-first and paginates")
    func listDirectory() async throws {
        let fixture = try makeFixture()
        try fixture.write("b.txt", "b")
        try fixture.write("a.txt", "a")
        try fixture.write("dir/nested.txt", "n")

        let tool = WorkspaceListDirectoryTool(environment: fixture.environment)
        let output = try await tool.execute(
            .init(path: "."), context: fixture.context
        )
        #expect(output.summary.contains("dir\tdir") == false) // dir rows use full relative path
        #expect(output.summary.contains("a.txt"))
        #expect(output.summary.contains("b.txt"))
        #expect(output.summary.contains("dir"))
        #expect(!output.summary.contains("nextPageToken"))
        // Directories sort before files.
        let lines = output.summary.components(separatedBy: "\n")
        let dirIndex = lines.firstIndex { $0.contains("\tdir") || $0.hasPrefix("dir\t") }
        let aIndex = lines.firstIndex { $0.hasSuffix("a.txt") }
        if let dirIndex, let aIndex {
            #expect(dirIndex < aIndex)
        }
    }

    @Test("listDirectory paginates in pages of 200")
    func listDirectoryPagination() async throws {
        let fixture = try makeFixture()
        for index in 0..<205 {
            try fixture.write(String(format: "f%03d.txt", index), "x")
        }
        let service = try fixture.environment.makeService()
        let first = try service.listDirectory(".", pageToken: nil)
        #expect(first.entries.count == 200)
        #expect(first.nextPageToken != nil)
        let second = try service.listDirectory(".", pageToken: first.nextPageToken)
        #expect(second.entries.count == 5)
        #expect(second.nextPageToken == nil)
        // No overlap between pages.
        let firstNames = Set(first.entries.map(\.name))
        #expect(second.entries.allSatisfy { !firstNames.contains($0.name) })
    }

    // MARK: readFile

    @Test("listDirectory filters by name substring and entry kind")
    func listDirectoryFilters() async throws {
        let fixture = try makeFixture()
        try fixture.write("notes-alpha.txt", "a")
        try fixture.write("notes-beta.md", "b")
        try fixture.write("image.png", "p")
        try fixture.write("docs/readme.txt", "r")

        let tool = WorkspaceListDirectoryTool(environment: fixture.environment)
        let named = try await tool.execute(
            .init(path: ".", nameContains: "notes"), context: fixture.context
        )
        #expect(named.summary.contains("notes-alpha.txt"))
        #expect(named.summary.contains("notes-beta.md"))
        #expect(!named.summary.contains("image.png"))

        let filesOnly = try await tool.execute(
            .init(path: ".", kind: "file"), context: fixture.context
        )
        #expect(!filesOnly.summary.contains("\tdocs"))
        #expect(filesOnly.summary.contains("image.png"))

        let dirsOnly = try await tool.execute(
            .init(path: ".", kind: "dir"), context: fixture.context
        )
        #expect(dirsOnly.summary.contains("\tdocs"))
        #expect(!dirsOnly.summary.contains("notes-alpha.txt"))

        #expect(throws: WorkspaceToolError.self) {
            try tool.validate(.init(path: ".", kind: "symlink"))
        }
    }

    @Test("listDirectory filters apply before pagination")
    func listDirectoryFilterPagination() throws {
        let fixture = try makeFixture()
        for index in 0..<205 {
            try fixture.write(String(format: "keep-%03d.txt", index), "x")
        }
        for index in 0..<50 {
            try fixture.write(String(format: "skip-%03d.txt", index), "x")
        }
        let service = try fixture.environment.makeService()
        let first = try service.listDirectory(".", pageToken: nil, nameContains: "keep")
        #expect(first.entries.count == 200)
        #expect(first.entries.allSatisfy { $0.name.hasPrefix("keep-") })
        let second = try service.listDirectory(".", pageToken: first.nextPageToken, nameContains: "keep")
        #expect(second.entries.count == 5)
        #expect(second.nextPageToken == nil)
    }

    @Test("searchFiles filename mode matches file and directory names")
    func searchFileNames() async throws {
        let fixture = try makeFixture()
        try fixture.write("reports/annual-report-2026.pdf", "x")
        try fixture.write("reports/monthly-summary.txt", "needle content")
        try fixture.write("src/report_generator.py", "print(1)")

        let tool = WorkspaceSearchFilesTool(environment: fixture.environment)
        let output = try await tool.execute(
            .init(query: "report", mode: "filename"), context: fixture.context
        )
        #expect(output.summary.contains("mode=filename"))
        #expect(output.summary.contains("annual-report-2026.pdf"))
        #expect(output.summary.contains("report_generator.py"))
        #expect(!output.summary.contains("monthly-summary.txt:1"))

        let dirHit = try await tool.execute(
            .init(query: "reports", mode: "filename"), context: fixture.context
        )
        #expect(dirHit.summary.contains("reports/"))

        // Content mode is unchanged and still searches text.
        let content = try await tool.execute(
            .init(query: "needle"), context: fixture.context
        )
        #expect(content.summary.contains("monthly-summary.txt:1"))

        #expect(throws: WorkspaceToolError.self) {
            try tool.validate(.init(query: "x", mode: "regex"))
        }
    }

    // MARK: readFile

    @Test("readFile returns full content for small files")
    func readFile() async throws {
        let fixture = try makeFixture()
        try fixture.write("hello.txt", "line1\nline2\nline3")
        let tool = WorkspaceReadFileTool(environment: fixture.environment)
        let output = try await tool.execute(.init(path: "hello.txt"), context: fixture.context)
        #expect(output.summary.contains("truncated=false"))
        #expect(output.summary.contains("totalLines=3"))
        #expect(output.summary.contains("line2"))
    }

    @Test("readFile truncates past 64 KiB and honors offset")
    func readFileTruncation() async throws {
        let fixture = try makeFixture()
        let big = String(repeating: "0123456789\n", count: 10_000) // 110_000 bytes
        try fixture.write("big.txt", big)

        let service = try fixture.environment.makeService()
        let first = try service.readFile("big.txt", byteOffset: 0)
        #expect(first.truncated)
        #expect(first.totalLines == 10_000)
        #expect(Data(first.text.utf8).count <= WorkspaceFileService.readChunkBytes)

        let second = try service.readFile("big.txt", byteOffset: WorkspaceFileService.readChunkBytes)
        #expect(second.byteOffset == WorkspaceFileService.readChunkBytes)
        #expect(!second.truncated)
    }

    @Test("editor reads the complete text instead of a truncated tool window")
    func editorReadsCompleteText() throws {
        let fixture = try makeFixture()
        let big = String(repeating: "let value = 42\n", count: 8_000)
        try fixture.write("large.swift", big)

        let service = try fixture.environment.makeService()
        let content = try service.readFileForEditing("large.swift")

        #expect(content.text == big)
        #expect(!content.truncated)
        #expect(content.byteOffset == 0)
        #expect(content.totalLines == 8_000)
    }

    @Test("editor rejects files that cannot be safely written in full")
    func editorRejectsOversizedWrite() throws {
        let fixture = try makeFixture()
        try fixture.write("too-large.txt", String(repeating: "x", count: 129))
        let service = WorkspaceFileService(guard: WorkspacePathGuard(
            rootURL: fixture.root,
            maxReadBytes: 1_024,
            maxWriteBytes: 128
        ))

        do {
            _ = try service.readFileForEditing("too-large.txt")
            Issue.record("expected tooLarge")
        } catch let error as WorkspaceToolError {
            guard case .tooLarge(let limit) = error else {
                Issue.record("expected tooLarge, got \(error)")
                return
            }
            #expect(limit == 128)
        }
    }

    @Test("readFile on a directory fails with isDirectory")
    func readFileDirectory() async throws {
        let fixture = try makeFixture()
        try fixture.write("sub/file.txt", "x")
        let tool = WorkspaceReadFileTool(environment: fixture.environment)
        do {
            _ = try await tool.execute(.init(path: "sub"), context: fixture.context)
            Issue.record("expected isDirectory")
        } catch let error as WorkspaceToolError {
            guard case .isDirectory = error else {
                Issue.record("expected isDirectory, got \(error)")
                return
            }
        }
    }

    // MARK: searchFiles

    @Test("searchFiles finds case-insensitive hits with context")
    func searchFiles() async throws {
        let fixture = try makeFixture()
        try fixture.write("one.txt", "alpha\nBETA line\ngamma")
        try fixture.write("two.md", "nothing here")
        try fixture.write("sub/three.txt", "beta again")

        let tool = WorkspaceSearchFilesTool(environment: fixture.environment)
        let output = try await tool.execute(.init(query: "beta"), context: fixture.context)
        #expect(output.summary.contains("hits=2"))
        #expect(output.summary.contains("one.txt:2"))
        #expect(output.summary.contains("sub/three.txt:1"))
    }

    @Test("searchFiles skips binary files and .git, caps results")
    func searchFilesLimits() async throws {
        let fixture = try makeFixture()
        var binary = Data("token\0binary".utf8)
        binary.append(contentsOf: [0, 1, 2])
        try binary.write(to: fixture.root.appendingPathComponent("bin.dat"))
        try fixture.write(".git/config", "token") // hidden + secret; never searched
        try fixture.write("id_rsa", "token private key")
        try fixture.write("certs/private.key", "token certificate")
        for index in 0..<120 {
            try fixture.write(String(format: "m%03d.txt", index), "token here")
        }

        let service = try fixture.environment.makeService()
        let hits = try service.search(query: "token", in: "")
        #expect(hits.count == WorkspaceFileService.maxSearchHits)
        #expect(hits.allSatisfy {
            !$0.relativePath.hasPrefix(".git")
                && $0.relativePath != "bin.dat"
                && $0.relativePath != "id_rsa"
                && $0.relativePath != "certs/private.key"
        })
    }

    // MARK: inspectFileMetadata

    @Test("inspectFileMetadata reports size/sha256/UTI")
    func metadata() async throws {
        let fixture = try makeFixture()
        try fixture.write("meta.json", #"{"a":1}"#)
        let tool = WorkspaceInspectMetadataTool(environment: fixture.environment)
        let output = try await tool.execute(.init(path: "meta.json"), context: fixture.context)
        #expect(output.summary.contains("size=7"))
        #expect(output.summary.contains("uti=public.json"))
        #expect(output.summary.contains("isDirectory=false"))
        let expectedSHA = WorkspaceFileService.sha256Hex(of: Data(#"{"a":1}"#.utf8))
        #expect(output.summary.contains(expectedSHA))
    }

    // MARK: createFile / writeFile

    @Test("createFile writes content and refuses to overwrite without opt-in")
    func createFile() async throws {
        let fixture = try makeFixture()
        let tool = WorkspaceCreateFileTool(environment: fixture.environment)

        let output = try await tool.execute(
            .init(path: "new/note.txt", content: "hello"), context: fixture.context
        )
        #expect(output.summary.contains("bytes=5"))
        #expect(output.artifacts.count == 1)
        #expect(output.artifacts.first?.mimeType == "text/x-diff")
        #expect(try fixture.read("new/note.txt") == "hello")

        do {
            _ = try await tool.execute(
                .init(path: "new/note.txt", content: "other"), context: fixture.context
            )
            Issue.record("expected alreadyExistsOverwritable")
        } catch let error as WorkspaceToolError {
            guard case .alreadyExistsOverwritable = error else {
                Issue.record("expected alreadyExistsOverwritable, got \(error)")
                return
            }
            // The failure must guide the caller to the supported escape hatches.
            #expect(error.localizedDescription.contains("workspace.writeFile"))
            #expect(error.localizedDescription.contains("overwrite=true"))
            // The stable machine-readable code stays alreadyExists.
            #expect(error.code == "alreadyExists")
            #expect(error.structuredSummary.contains(#""code":"alreadyExists""#))
        }
        // Untouched.
        #expect(try fixture.read("new/note.txt") == "hello")
    }

    @Test("createFile with overwrite=true replaces existing content")
    func createFileOverwrite() async throws {
        let fixture = try makeFixture()
        try fixture.write("doc.md", "v1")
        let tool = WorkspaceCreateFileTool(environment: fixture.environment)

        let output = try await tool.execute(
            .init(path: "doc.md", content: "v2-longer", overwrite: true), context: fixture.context
        )
        #expect(output.summary.contains("created=doc.md"))
        #expect(output.summary.contains("bytes=9"))
        #expect(output.artifacts.count == 1)
        #expect(try fixture.read("doc.md") == "v2-longer")

        // Creating at a fresh path still succeeds with the flag set.
        _ = try await tool.execute(
            .init(path: "fresh.md", content: "new", overwrite: true), context: fixture.context
        )
        #expect(try fixture.read("fresh.md") == "new")
    }

    @Test("writeFile overwrites and detects mtime/sha conflicts")
    func writeFileConflict() async throws {
        let fixture = try makeFixture()
        try fixture.write("doc.txt", "v1")
        let writeTool = WorkspaceWriteFileTool(environment: fixture.environment)
        let metadataTool = WorkspaceInspectMetadataTool(environment: fixture.environment)

        // Baseline metadata.
        let service = try fixture.environment.makeService()
        let baseline = try service.metadata("doc.txt")

        // Correct expectations succeed.
        let ok = try await writeTool.execute(
            .init(path: "doc.txt", content: "v2",
                  expectedMtime: baseline.mtime, expectedSHA256: baseline.sha256),
            context: fixture.context
        )
        #expect(ok.summary.contains("written=doc.txt"))
        #expect(ok.artifacts.count == 1)
        #expect(try fixture.read("doc.txt") == "v2")

        // Stale sha → conflict, file untouched.
        do {
            _ = try await writeTool.execute(
                .init(path: "doc.txt", content: "v3",
                      expectedSHA256: baseline.sha256),
                context: fixture.context
            )
            Issue.record("expected conflict")
        } catch let error as WorkspaceToolError {
            guard case .conflict = error else {
                Issue.record("expected conflict, got \(error)")
                return
            }
        }
        #expect(try fixture.read("doc.txt") == "v2")

        _ = metadataTool // metadata tool used indirectly via service above
    }

    // MARK: general plain-text matrix

    @Test("Every plain-text type supports create, read, append, replace, write and diff-based editing")
    func plainTextMatrix() async throws {
        let fixture = try makeFixture()
        let create = WorkspaceCreateFileTool(environment: fixture.environment)
        let read = WorkspaceReadFileTool(environment: fixture.environment)
        let append = WorkspaceAppendFileTool(environment: fixture.environment)
        let replace = WorkspaceReplaceTextTool(environment: fixture.environment)
        let write = WorkspaceWriteFileTool(environment: fixture.environment)
        let patch = WorkspaceApplyPatchTool(environment: fixture.environment)
        let service = try fixture.environment.makeService()

        let cases: [(path: String, text: String)] = [
            ("scripts/job.py", "#!/usr/bin/env python3\nprint('你好')\n"),
            ("web/page.html", "<!doctype html>\n<html><body>你好</body></html>\n"),
            ("web/style.css", "body { color: #123456; }\n"),
            ("web/app.js", "const 名称 = 'Floe';\nconsole.log(名称);\n"),
            ("data/data.json", "{\"name\":\"测试\",\"count\":1}\n"),
            ("data/config.yaml", "name: 测试\nitems:\n  - first\n"),
            ("data/table.csv", "名称,数量\n苹果,2\n"),
            ("docs/paper.tex", "\\documentclass{article}\n\\begin{document}\n你好\n\\end{document}\n"),
            ("docs/main.swift", "let 名称 = \"Floe\"\nprint(名称)\n"),
            ("docs/notes.txt", "plain text\n"),
            ("docs/README", "extensionless text\n"),
            ("docs/mystery.xyz", "unknown extension text\n"),
            ("文档/待办", "中文路径与无扩展名\n")
        ]

        for (index, item) in cases.enumerated() {
            let created = try await create.execute(
                .init(path: item.path, content: item.text), context: fixture.context)
            #expect(try fixture.read(item.path) == item.text, "create failed for \(item.path)")

            let firstRead = try await read.execute(.init(path: item.path), context: fixture.context)
            #expect(try pageBody(firstRead.summary) == item.text, "read failed for \(item.path)")
            #expect(try field("totalBytes", in: firstRead.summary) == String(item.text.utf8.count))

            let appendedText = "\nappended-\(index)"
            let appended = try await append.execute(
                .init(path: item.path, content: appendedText,
                      expectedSHA256: try field("sha256", in: created.summary)),
                context: fixture.context)
            #expect(try fixture.read(item.path) == item.text + appendedText,
                    "append failed for \(item.path)")

            let replaced = try await replace.execute(
                .init(path: item.path, oldText: "appended-\(index)", newText: "替换-\(index)",
                      expectedSHA256: try field("sha256", in: appended.summary)),
                context: fixture.context)
            let replacedText = item.text + "\n替换-\(index)"
            #expect(try fixture.read(item.path) == replacedText,
                    "replace failed for \(item.path)")

            let finalText = "final-\(index)-\(item.path)\n"
            _ = try await write.execute(
                .init(path: item.path, content: finalText,
                      expectedSHA256: try field("sha256", in: replaced.summary)),
                context: fixture.context)
            #expect(try fixture.read(item.path) == finalText, "write failed for \(item.path)")

            let patchedText = finalText + "patched\n"
            let diff = service.diff(original: finalText, modified: patchedText, label: item.path)
            #expect(!diff.isEmpty)
            _ = try await patch.execute(.init(path: item.path, patch: diff), context: fixture.context)
            #expect(try fixture.read(item.path) == patchedText, "patch failed for \(item.path)")

            // Independent reread through a fresh guard/service, not the writer.
            let fresh = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: fixture.root))
            #expect(try fresh.readFileForEditing(item.path).text == patchedText)
        }
    }

    @Test("UTF-8 BOM, CRLF and multibyte bytes survive append, replace, write and patch")
    func bomAndCRLFRoundTrip() async throws {
        let fixture = try makeFixture()
        let read = WorkspaceReadFileTool(environment: fixture.environment)
        let append = WorkspaceAppendFileTool(environment: fixture.environment)
        let replace = WorkspaceReplaceTextTool(environment: fixture.environment)
        let write = WorkspaceWriteFileTool(environment: fixture.environment)
        let patch = WorkspaceApplyPatchTool(environment: fixture.environment)

        var original = Data(WorkspaceTextPolicy.utf8BOM)
        original.append(Data("第一行\r\nsecond line\r\n".utf8))
        try fixture.writeData("docs/编码.tex", original)

        // The read path preserves the BOM as U+FEFF instead of silently
        // consuming it, so the complete text is byte-exact.
        let firstRead = try await read.execute(.init(path: "docs/编码.tex"), context: fixture.context)
        #expect(try pageBody(firstRead.summary).hasPrefix("\u{FEFF}"))
        #expect(try field("bytes", in: firstRead.summary) == String(original.count))
        let editing = try fixture.environment.makeService().readFileForEditing("docs/编码.tex")
        #expect(editing.text.hasPrefix("\u{FEFF}"))
        #expect(Data(editing.text.utf8) == original)

        let appendSuffix = "第三行 😀\r\n"
        let appended = try await append.execute(
            .init(path: "docs/编码.tex", content: appendSuffix,
                  expectedSHA256: WorkspaceFileService.sha256Hex(of: original)),
            context: fixture.context)
        var expected = original
        expected.append(Data(appendSuffix.utf8))
        #expect(try fixture.readData("docs/编码.tex") == expected)

        let replaced = try await replace.execute(
            .init(path: "docs/编码.tex", oldText: "second line", newText: "SECOND line",
                  expectedSHA256: try field("sha256", in: appended.summary)),
            context: fixture.context)
        // String(decoding:) keeps the leading U+FEFF byte-for-byte; the
        // Foundation String(data:encoding:.utf8) initializer would strip it.
        expected = Data(String(decoding: expected, as: UTF8.self).replacingOccurrences(
            of: "second line", with: "SECOND line").utf8)
        #expect(try fixture.readData("docs/编码.tex") == expected)
        #expect(expected.starts(with: Data(WorkspaceTextPolicy.utf8BOM)))

        let finalText = "\u{FEFF}final\r\nline\r\n"
        _ = try await write.execute(
            .init(path: "docs/编码.tex", content: finalText,
                  expectedSHA256: try field("sha256", in: replaced.summary)),
            context: fixture.context)
        #expect(try fixture.readData("docs/编码.tex") == Data(finalText.utf8))

        let service = try fixture.environment.makeService()
        let patchedText = finalText + "patched\r\n"
        let diff = service.diff(original: finalText, modified: patchedText, label: "docs/编码.tex")
        #expect(!diff.isEmpty)
        _ = try await patch.execute(.init(path: "docs/编码.tex", patch: diff), context: fixture.context)
        #expect(try fixture.readData("docs/编码.tex") == Data(patchedText.utf8))
    }

    @Test("Binary and UTF-16 reads/edits are refused without changing the original bytes")
    func binaryAndNonUTF8Refused() async throws {
        let fixture = try makeFixture()
        let read = WorkspaceReadFileTool(environment: fixture.environment)
        let append = WorkspaceAppendFileTool(environment: fixture.environment)
        let replace = WorkspaceReplaceTextTool(environment: fixture.environment)
        let service = try fixture.environment.makeService()

        let binary = Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0xFF, 0xFE])
        try fixture.writeData("docs/blob.xyz", binary)
        for call in [
            { try await read.execute(.init(path: "docs/blob.xyz"), context: fixture.context) },
            { try await append.execute(.init(path: "docs/blob.xyz", content: "x"), context: fixture.context) },
            { try await replace.execute(.init(path: "docs/blob.xyz", oldText: "P", newText: "Q"), context: fixture.context) }
        ] as [() async throws -> ToolExecutionOutput] {
            do {
                _ = try await call()
                Issue.record("binary content must be refused")
            } catch let error as WorkspaceToolError {
                guard case .invalidArguments = error else {
                    Issue.record("expected invalidArguments, got \(error)")
                    return
                }
            }
        }
        #expect(try fixture.readData("docs/blob.xyz") == binary)
        #expect(throws: WorkspaceToolError.self) { _ = try service.readFileForEditing("docs/blob.xyz") }

        let utf16 = "\u{FEFF}hello 你好"
        let utf16Data = try #require(utf16.data(using: .utf16))
        try fixture.writeData("docs/utf16.txt", utf16Data)
        do {
            _ = try await append.execute(.init(path: "docs/utf16.txt", content: "x"), context: fixture.context)
            Issue.record("non-UTF-8 text must not be silently converted")
        } catch let error as WorkspaceToolError {
            guard case .invalidArguments = error else {
                Issue.record("expected invalidArguments, got \(error)")
                return
            }
        }
        #expect(try fixture.readData("docs/utf16.txt") == utf16Data)

        // Text tools never create NUL-bearing (binary) content.
        let create = WorkspaceCreateFileTool(environment: fixture.environment)
        do {
            _ = try await create.execute(
                .init(path: "docs/nul.txt", content: "a\u{0}b"), context: fixture.context)
            Issue.record("NUL content must be refused")
        } catch let error as WorkspaceToolError {
            guard case .invalidArguments = error else {
                Issue.record("expected invalidArguments, got \(error)")
                return
            }
        }
        #expect(!fixture.exists("docs/nul.txt"))
    }

    // MARK: applyPatch

    @Test("applyPatch applies hunks and reports counts")
    func applyPatchSuccess() async throws {
        let fixture = try makeFixture()
        try fixture.write("code.swift", "one\ntwo\nthree\nfour\nfive\n")
        let patch = """
        --- a/code.swift
        +++ b/code.swift
        @@ -2,3 +2,3 @@
         two
        -three
        +THREE
         four
        """
        let tool = WorkspaceApplyPatchTool(environment: fixture.environment)
        let output = try await tool.execute(
            .init(path: "code.swift", patch: patch), context: fixture.context
        )
        #expect(output.summary.contains("hunks=1"))
        #expect(output.summary.contains("added=1"))
        #expect(output.summary.contains("removed=1"))
        #expect(output.artifacts.count == 1)
        #expect(output.artifacts.first?.relativePath.hasPrefix("ChangeArtifacts/") == true)
        #expect(try fixture.read("code.swift") == "one\ntwo\nTHREE\nfour\nfive\n")
    }

    @Test("applyPatch failure leaves the file untouched")
    func applyPatchAtomicity() async throws {
        let fixture = try makeFixture()
        let original = "alpha\nbeta\ngamma\n"
        try fixture.write("file.txt", original)
        // Context does not match ("beta" is actually on line 2, but the hunk
        // expects "WRONG").
        let patch = """
        @@ -1,3 +1,3 @@
         alpha
        -WRONG
        +changed
         gamma
        """
        let tool = WorkspaceApplyPatchTool(environment: fixture.environment)
        do {
            _ = try await tool.execute(
                .init(path: "file.txt", patch: patch), context: fixture.context
            )
            Issue.record("expected invalidPatch")
        } catch let error as WorkspaceToolError {
            guard case .invalidPatch = error else {
                Issue.record("expected invalidPatch, got \(error)")
                return
            }
        }
        #expect(try fixture.read("file.txt") == original)
    }

    @Test("Extreme patch coordinates are rejected without trapping")
    func applyPatchCoordinateOverflowRejected() async throws {
        let fixture = try makeFixture()
        try fixture.write("overflow.txt", "a\nb\n")
        let service = try fixture.environment.makeService()
        let patch = """
        --- a/overflow.txt
        +++ b/overflow.txt
        @@ -9223372036854775807,2 +1,2 @@
        -a
        -b
        +x
        +y
        """
        do {
            _ = try service.applyPatch("overflow.txt", patch: patch)
            Issue.record("expected invalidPatch")
        } catch let error as WorkspaceToolError {
            guard case .invalidPatch = error else {
                Issue.record("expected invalidPatch, got \(error)")
                return
            }
        }
        #expect(try fixture.read("overflow.txt") == "a\nb\n")
    }

    @Test("Multi-file patches are rejected")
    func applyPatchMultiFileRejected() async throws {
        let fixture = try makeFixture()
        try fixture.write("a.txt", "x\n")
        let patch = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -x
        +y
        """
        let tool = WorkspaceApplyPatchTool(environment: fixture.environment)
        do {
            _ = try await tool.execute(
                .init(path: "a.txt", patch: patch), context: fixture.context
            )
            Issue.record("expected invalidPatch")
        } catch let error as WorkspaceToolError {
            guard case .invalidPatch = error else {
                Issue.record("expected invalidPatch, got \(error)")
                return
            }
        }
        #expect(try fixture.read("a.txt") == "x\n")
    }

    // MARK: moveFile / deleteFile

    @Test("moveFile relocates files and refuses existing destinations")
    func moveFile() async throws {
        let fixture = try makeFixture()
        try fixture.write("old.txt", "data")
        let tool = WorkspaceMoveFileTool(environment: fixture.environment)

        let output = try await tool.execute(
            .init(from: "old.txt", to: "renamed/new.txt"), context: fixture.context
        )
        #expect(output.summary.contains("old.txt -> renamed/new.txt"))
        #expect(!fixture.exists("old.txt"))
        #expect(try fixture.read("renamed/new.txt") == "data")

        try fixture.write("occupied.txt", "other")
        do {
            _ = try await tool.execute(
                .init(from: "renamed/new.txt", to: "occupied.txt"), context: fixture.context
            )
            Issue.record("expected alreadyExists")
        } catch let error as WorkspaceToolError {
            guard case .alreadyExists = error else {
                Issue.record("expected alreadyExists, got \(error)")
                return
            }
        }
    }

    @Test("deleteFile removes files and empty directories only")
    func deleteFile() async throws {
        let fixture = try makeFixture()
        try fixture.write("gone.txt", "x")
        try fixture.write("keep/inner.txt", "y")
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("empty-dir"),
            withIntermediateDirectories: true
        )
        let tool = WorkspaceDeleteFileTool(environment: fixture.environment)

        _ = try await tool.execute(.init(path: "gone.txt"), context: fixture.context)
        #expect(!fixture.exists("gone.txt"))

        _ = try await tool.execute(.init(path: "empty-dir"), context: fixture.context)
        #expect(!fixture.exists("empty-dir"))

        // Non-empty directory refused.
        do {
            _ = try await tool.execute(.init(path: "keep"), context: fixture.context)
            Issue.record("expected refusal for non-empty directory")
        } catch let error as WorkspaceToolError {
            guard case .invalidArguments = error else {
                Issue.record("expected invalidArguments, got \(error)")
                return
            }
        }
        #expect(fixture.exists("keep/inner.txt"))

        // Missing path → notFound.
        do {
            _ = try await tool.execute(.init(path: "nope.txt"), context: fixture.context)
            Issue.record("expected notFound")
        } catch let error as WorkspaceToolError {
            guard case .notFound = error else {
                Issue.record("expected notFound, got \(error)")
                return
            }
        }
    }

    @Test("deleteFile recursive=true removes non-empty directories")
    func deleteRecursive() async throws {
        let fixture = try makeFixture()
        try fixture.write("tree/a.txt", "x")
        try fixture.write("tree/sub/b.txt", "y")
        let tool = WorkspaceDeleteFileTool(environment: fixture.environment)

        _ = try await tool.execute(
            .init(path: "tree", recursive: true), context: fixture.context
        )
        #expect(!fixture.exists("tree"))
    }

    @Test("mutating the workspace root is always rejected")
    func rejectsRootMutation() async throws {
        let fixture = try makeFixture()
        try fixture.write("keep.txt", "important")
        let delete = WorkspaceDeleteFileTool(environment: fixture.environment)
        let copy = WorkspaceCopyFileTool(environment: fixture.environment)

        await #expect(throws: (any Error).self) {
            _ = try await delete.execute(
                .init(path: ".", recursive: true), context: fixture.context
            )
        }
        await #expect(throws: (any Error).self) {
            _ = try await copy.execute(
                .init(from: ".", to: "nested-copy"), context: fixture.context
            )
        }
        #expect(fixture.exists("keep.txt"))
    }

    @Test("copyFile copies files and directories")
    func copyFile() async throws {
        let fixture = try makeFixture()
        try fixture.write("src.txt", "data")
        try fixture.write("dir/inner.txt", "y")
        let tool = WorkspaceCopyFileTool(environment: fixture.environment)

        let fileOut = try await tool.execute(
            .init(from: "src.txt", to: "copied.txt"), context: fixture.context
        )
        #expect(fileOut.summary.contains("src.txt -> copied.txt"))
        #expect(try fixture.read("copied.txt") == "data")

        _ = try await tool.execute(
            .init(from: "dir", to: "dir-copy"), context: fixture.context
        )
        #expect(try fixture.read("dir-copy/inner.txt") == "y")
        #expect(try fixture.read("dir/inner.txt") == "y")
    }

    // MARK: Guard integration through tools

    @Test("Tools reject escaping and secret paths")
    func guardIntegration() async throws {
        let fixture = try makeFixture()
        let readTool = WorkspaceReadFileTool(environment: fixture.environment)
        let createTool = WorkspaceCreateFileTool(environment: fixture.environment)

        do {
            _ = try await readTool.execute(.init(path: "../outside.txt"), context: fixture.context)
            Issue.record("expected escapesRoot")
        } catch let error as WorkspaceToolError {
            guard case .escapesRoot = error else {
                Issue.record("expected escapesRoot, got \(error)")
                return
            }
        }
        do {
            _ = try await createTool.execute(
                .init(path: ".env", content: "TOKEN=1"), context: fixture.context
            )
            Issue.record("expected secretFile")
        } catch let error as WorkspaceToolError {
            guard case .secretFile = error else {
                Issue.record("expected secretFile, got \(error)")
                return
            }
        }
        #expect(!fixture.exists(".env"))
    }

    // MARK: Host scope

    @Test("Host scope arguments fail with unsupportedScope")
    func hostScopeRejected() async throws {
        let fixture = try makeFixture()
        let readTool = WorkspaceReadFileTool(environment: fixture.environment)
        let deleteTool = WorkspaceDeleteFileTool(environment: fixture.environment)
        try fixture.write("x.txt", "x")

        for call in [
            { try await readTool.execute(.init(path: "x.txt", scope: "host"), context: fixture.context) },
            { try await deleteTool.execute(.init(path: "x.txt", scope: "host"), context: fixture.context) }
        ] as [() async throws -> ToolExecutionOutput] {
            do {
                _ = try await call()
                Issue.record("expected unsupportedScope")
            } catch let error as WorkspaceToolError {
                guard case .unsupportedScope = error else {
                    Issue.record("expected unsupportedScope, got \(error)")
                    continue
                }
            }
        }
        #expect(fixture.exists("x.txt"))
    }

    @Test("Canonical host scope is rejected even when JSON omits scope")
    func canonicalHostScopeRejected() async throws {
        let fixture = try makeFixture()
        try fixture.write("x.txt", "x")
        let context = ToolContext(
            runID: UUID(),
            scope: .host(UUID()),
            cancellation: CancellationToken()
        )
        let tool = WorkspaceDeleteFileTool(environment: fixture.environment)
        do {
            _ = try await tool.execute(.init(path: "x.txt"), context: context)
            Issue.record("expected unsupportedScope")
        } catch let error as WorkspaceToolError {
            guard case .unsupportedScope = error else {
                Issue.record("expected unsupportedScope, got \(error)")
                return
            }
        }
        #expect(fixture.exists("x.txt"))
    }

    @Test("Task file ceiling rejects siblings and dot-dot scope bypass")
    func taskFileCeiling() async throws {
        let fixture = try makeFixture()
        try fixture.write("allowed/readme.txt", "allowed")
        try fixture.write("secret.txt", "secret")
        let context = ToolContext(
            runID: UUID(),
            workspaceRootURL: fixture.root,
            allowedWorkspacePaths: ["allowed"],
            cancellation: CancellationToken()
        )
        let tool = WorkspaceReadFileTool(environment: fixture.environment)
        let append = WorkspaceAppendFileTool(environment: fixture.environment)

        let allowed = try await tool.execute(.init(path: "allowed/readme.txt"), context: context)
        #expect(allowed.summary.contains("allowed"))
        _ = try await append.execute(.init(path: "allowed/readme.txt", content: "!"), context: context)
        #expect(try fixture.read("allowed/readme.txt") == "allowed!")

        for path in ["secret.txt", "allowed/../secret.txt", "allowed/sub/../../secret.txt"] {
            do {
                _ = try await tool.execute(.init(path: path), context: context)
                Issue.record("expected task file scope rejection for \(path)")
            } catch let error as FloeError {
                guard case .validationFailed = error else {
                    Issue.record("expected validationFailed, got \(error)")
                    continue
                }
            }
        }
        do {
            _ = try await append.execute(.init(path: "secret.txt", content: "x"), context: context)
            Issue.record("append must respect the task file scope ceiling")
        } catch let error as FloeError {
            guard case .validationFailed = error else {
                Issue.record("expected validationFailed, got \(error)")
                return
            }
        }
        #expect(try fixture.read("secret.txt") == "secret")
    }

    // MARK: Cancellation

    @Test("Cancelled context aborts before any file mutation")
    func cancellation() async throws {
        let fixture = try makeFixture()
        let token = CancellationToken()
        token.cancel()
        let context = ToolContext(runID: UUID(), cancellation: token)

        let createTool = WorkspaceCreateFileTool(environment: fixture.environment)
        do {
            _ = try await createTool.execute(
                .init(path: "never.txt", content: "x"), context: context
            )
            Issue.record("expected cancellation")
        } catch let error as FloeError {
            #expect(error == .cancelled)
        }
        #expect(!fixture.exists("never.txt"))

        try fixture.write("existing.txt", "original")
        let appendTool = WorkspaceAppendFileTool(environment: fixture.environment)
        do {
            _ = try await appendTool.execute(
                .init(path: "existing.txt", content: "never"), context: context
            )
            Issue.record("expected cancellation before append")
        } catch let error as FloeError {
            #expect(error == .cancelled)
        }
        #expect(try fixture.read("existing.txt") == "original")
    }

    // MARK: Missing workspace

    @Test("No workspace root yields a structured failure, not a crash")
    func missingWorkspace() async throws {
        let environment = WorkspaceToolEnvironment(rootProvider: { nil })
        let tool = WorkspaceReadFileTool(environment: environment)
        let context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        do {
            _ = try await tool.execute(.init(path: "x.txt"), context: context)
            Issue.record("expected notFound")
        } catch let error as WorkspaceToolError {
            guard case .notFound = error else {
                Issue.record("expected notFound, got \(error)")
                return
            }
        }
    }

    // MARK: diff generation

    @Test("diff produces valid unified output")
    func diffGeneration() throws {
        let fixture = try makeFixture()
        let service = try fixture.environment.makeService()
        let diffText = service.diff(
            original: "a\nb\nc\n",
            modified: "a\nB\nc\n",
            label: "f.txt"
        )
        #expect(diffText.contains("--- a/f.txt"))
        #expect(diffText.contains("+++ b/f.txt"))
        #expect(diffText.contains("-b"))
        #expect(diffText.contains("+B"))
        // Identical inputs produce no diff.
        #expect(service.diff(original: "same", modified: "same").isEmpty)
    }
}
