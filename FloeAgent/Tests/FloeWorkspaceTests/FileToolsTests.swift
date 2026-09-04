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

        func read(_ relative: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        }

        func exists(_ relative: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
        }
    }

    private func makeFixture() throws -> Fixture { try Fixture() }

    // MARK: Registration

    @Test("Registration wires all eleven tools into catalog and registry")
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
        for name in expected {
            #expect(ToolCatalog.descriptor(named: name) != nil, "descriptor missing for \(name)")
            #expect(registry.runner(named: name) != nil, "runner missing for \(name)")
        }
        let read = ToolCatalog.descriptor(named: "workspace.readFile")
        #expect(read?.isSideEffecting == false)
        #expect(read?.riskLabels == [.readsFiles])
        let delete = ToolCatalog.descriptor(named: "workspace.deleteFile")
        #expect(delete?.isSideEffecting == true)
        #expect(delete?.riskLabels == [.writesFiles, .deletesFiles])
    }

    // MARK: listDirectory

    @Test("UTF-8 edits are extension-independent and preserve full contents", arguments: ["html", "py", "swift", "json", "md", "conf"])
    func textEdits(ext: String) async throws {
        let f = try makeFixture()
        let path = "sample." + ext
        let original = String(repeating: "x", count: 70_000) + "unique旧内容"
        try f.write(path, original)
        _ = try await WorkspaceAppendFileTool(environment: f.environment).execute(.init(path: path, content: "\nappended"), context: f.context)
        _ = try await WorkspaceReplaceTextTool(environment: f.environment).execute(.init(path: path, oldText: "unique旧内容", newText: "new内容"), context: f.context)
        #expect(try f.read(path) == String(repeating: "x", count: 70_000) + "new内容\nappended")
        await #expect(throws: WorkspaceToolError.self) {
            _ = try await WorkspaceAppendFileTool(environment: f.environment).execute(.init(path: path, content: "bad", expectedSHA256: "stale"), context: f.context)
        }
        #expect(try !f.read(path).hasSuffix("bad"))
    }

    @Test("Text transformations reject ambiguous matches and binary contents")
    func unsafeTextEdits() async throws {
        let f = try makeFixture()
        try f.write("a.py", "same same")
        await #expect(throws: WorkspaceToolError.self) {
            _ = try await WorkspaceReplaceTextTool(environment: f.environment).execute(.init(path: "a.py", oldText: "same", newText: "changed"), context: f.context)
        }
        #expect(try f.read("a.py") == "same same")
        try Data([0, 255, 12]).write(to: f.root.appendingPathComponent("binary.html"))
        await #expect(throws: WorkspaceToolError.self) {
            _ = try await WorkspaceAppendFileTool(environment: f.environment).execute(.init(path: "binary.html", content: "text"), context: f.context)
        }
    }

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

    @Test("createFile writes content and refuses to overwrite")
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
            Issue.record("expected alreadyExists")
        } catch let error as WorkspaceToolError {
            guard case .alreadyExists = error else {
                Issue.record("expected alreadyExists, got \(error)")
                return
            }
        }
        // Untouched.
        #expect(try fixture.read("new/note.txt") == "hello")
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

        let allowed = try await tool.execute(.init(path: "allowed/readme.txt"), context: context)
        #expect(allowed.summary.contains("allowed"))

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
