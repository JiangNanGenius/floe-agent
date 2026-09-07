// FloeWorkspaceTests — workspace.archive round-trip and extraction safety.

import Foundation
import Testing
import ZIPFoundation
@testable import FloeWorkspace
import FloeCore
import FloeTools

@Suite("FloeWorkspace.Archive")
struct ArchiveToolTests {

    private final class Fixture: @unchecked Sendable {
        let root: URL
        let environment: WorkspaceToolEnvironment
        let context: ToolContext

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-archive-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            environment = WorkspaceToolEnvironment(rootProvider: { [root] in root })
            context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        }

        deinit { try? FileManager.default.removeItem(at: root) }

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

    @Test("create + list + extract round-trips a directory")
    func roundTrip() async throws {
        let f = try Fixture()
        try f.write("project/a.txt", "alpha")
        try f.write("project/nested/b.md", "beta")
        let tool = WorkspaceArchiveTool(environment: f.environment)

        let created = try await tool.execute(
            .init(action: "create", source: "project", destinationFile: "pack.zip"),
            context: f.context
        )
        #expect(created.summary.contains("entries=2"))
        #expect(f.exists("pack.zip"))

        let listed = try await tool.execute(.init(action: "list", source: "pack.zip"), context: f.context)
        #expect(listed.summary.contains("project/a.txt"), "list was: \(listed.summary)")
        #expect(listed.summary.contains("project/nested/b.md"))

        let extracted = try await tool.execute(
            .init(action: "extract", source: "pack.zip", destinationDir: "unpacked"),
            context: f.context
        )
        #expect(extracted.summary.contains("entries=2"), "summary was: \(extracted.summary)")
        #expect(try f.read("unpacked/project/a.txt") == "alpha")
        #expect(try f.read("unpacked/project/nested/b.md") == "beta")
    }

    @Test("create packs a single file and refuses to overwrite")
    func singleFileAndNoOverwrite() async throws {
        let f = try Fixture()
        try f.write("note.txt", "hello")
        let tool = WorkspaceArchiveTool(environment: f.environment)
        let first = try await tool.execute(
            .init(action: "create", source: "note.txt", destinationFile: "note.zip"),
            context: f.context
        )
        #expect(first.summary.contains("entries=1"))
        await #expect(throws: WorkspaceToolError.self) {
            _ = try await tool.execute(
                .init(action: "create", source: "note.txt", destinationFile: "note.zip"),
                context: f.context
            )
        }
    }

    @Test("extraction skips traversal entries and keeps safe ones")
    func traversalSafety() async throws {
        let f = try Fixture()
        // Hand-craft an archive with a hostile entry plus one safe entry.
        let zipURL = f.root.appendingPathComponent("hostile.zip")
        let archive = try #require(Archive(url: zipURL, accessMode: .create))
        let safe = f.root.appendingPathComponent("safe.txt")
        try "safe".write(to: safe, atomically: true, encoding: .utf8)
        try archive.addEntry(with: "ok/safe.txt", fileURL: safe, compressionMethod: .deflate)
        let hostileData = Data("evil".utf8)
        try archive.addEntry(
            with: "../evil.txt",
            type: .file,
            uncompressedSize: Int64(hostileData.count)
        ) { position, size in
            hostileData[Int(position)..<Int(position) + size]
        }
        try FileManager.default.removeItem(at: safe)

        let tool = WorkspaceArchiveTool(environment: f.environment)
        let output = try await tool.execute(
            .init(action: "extract", source: "hostile.zip", destinationDir: "out"),
            context: f.context
        )
        #expect(output.summary.contains("entries=1"))
        #expect(output.summary.contains("skipped=1"))
        #expect(try f.read("out/ok/safe.txt") == "safe")
        #expect(!f.exists("evil.txt"))
        #expect(!f.exists("../evil.txt"))
    }

    @Test("validation rejects bad actions and absolute paths")
    func validation() {
        let f = try! Fixture()
        let tool = WorkspaceArchiveTool(environment: f.environment)
        #expect(throws: WorkspaceToolError.self) {
            try tool.validate(.init(action: "delete", source: "a.zip"))
        }
        #expect(throws: WorkspaceToolError.self) {
            try tool.validate(.init(action: "create", source: "/etc/passwd", destinationFile: "x.zip"))
        }
        #expect(throws: WorkspaceToolError.self) {
            try tool.validate(.init(action: "extract", source: "a.zip"))
        }
        #expect(throws: WorkspaceToolError.self) {
            try tool.validate(.init(action: "create", source: "a", destinationFile: "x.tar", format: "rar"))
        }
        #expect(throws: WorkspaceToolError.self) {
            try tool.validate(.init(action: "extract", source: "a.zip", destinationFile: "wrong"))
        }
        #expect(throws: WorkspaceToolError.self) {
            try tool.validate(.init(action: "extract", source: "a.gz", destinationDir: "wrong"))
        }
        #expect(throws: WorkspaceToolError.self) {
            try tool.validate(.init(action: "extract", source: "a.zip", destinationDir: "out", destinationFile: "both"))
        }
        #expect(throws: WorkspaceToolError.self) {
            try tool.validate(.init(action: "list", source: "a.zip", destinationDir: "unused"))
        }
        #expect(throws: WorkspaceToolError.self) {
            try tool.validate(.init(action: "extract", source: "a.gz", destinationFile: "directory/"))
        }
    }

    @Test("tar create + list + extract round-trips and auto-detects by extension")
    func tarRoundTrip() async throws {
        let f = try Fixture()
        try f.write("bundle/one.txt", "first")
        try f.write("bundle/deep/two.md", "second")
        let tool = WorkspaceArchiveTool(environment: f.environment)

        let created = try await tool.execute(
            .init(action: "create", source: "bundle", destinationFile: "pack.tar"),
            context: f.context
        )
        #expect(created.summary.contains("format=tar"))
        #expect(created.summary.contains("entries=2"))

        let listed = try await tool.execute(.init(action: "list", source: "pack.tar"), context: f.context)
        #expect(listed.summary.contains("format=tar"))
        #expect(listed.summary.contains("bundle/one.txt"))
        #expect(listed.summary.contains("bundle/deep/two.md"))

        let extracted = try await tool.execute(
            .init(action: "extract", source: "pack.tar", destinationDir: "untarred"),
            context: f.context
        )
        #expect(extracted.summary.contains("entries=2"))
        #expect(try f.read("untarred/bundle/one.txt") == "first")
        #expect(try f.read("untarred/bundle/deep/two.md") == "second")
    }

    @Test("tar archives produced by the system tar are readable")
    func systemTarCompatibility() async throws {
        let f = try Fixture()
        try f.write("fromsys/a.txt", "sys-alpha")
        try f.write("fromsys/sub/b.txt", "sys-beta")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cf", f.root.appendingPathComponent("sys.tar").path, "-C", f.root.path, "fromsys"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let tool = WorkspaceArchiveTool(environment: f.environment)
        let listed = try await tool.execute(.init(action: "list", source: "sys.tar"), context: f.context)
        #expect(listed.summary.contains("fromsys/a.txt"))
        let extracted = try await tool.execute(
            .init(action: "extract", source: "sys.tar", destinationDir: "sysout"),
            context: f.context
        )
        #expect(extracted.summary.contains("entries=2"))
        #expect(try f.read("sysout/fromsys/sub/b.txt") == "sys-beta")
    }

    @Test("our tar is readable by the system tar")
    func systemTarReadsOurs() async throws {
        let f = try Fixture()
        try f.write("mine/x.txt", "mine-content")
        let tool = WorkspaceArchiveTool(environment: f.environment)
        _ = try await tool.execute(
            .init(action: "create", source: "mine", destinationFile: "mine.tar"),
            context: f.context
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-tf", f.root.appendingPathComponent("mine.tar").path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(output.contains("mine/x.txt"))
    }

    @Test("7z extract and list work with the bundled decoder")
    func sevenZipRoundTrip() async throws {
        let f = try Fixture()
        // Pre-generated with py7zr: docs/a.txt ("seven content"), docs/sub/b.md ("nested content").
        let fixtureB64 = "N3q8ryccAATxEVM9lQAAAAAAAAAVAAAAAAAAAEGDdB8AOZlLMuk+sMxcerjw9jIiGcCOUfKPeSqx//7nWADgAIYAb10AAIEzB64Pz+swFA/r6p4BDWIDjdNMQj8OhwznT/BcjGhRgWpylQWCW3UePPTvJFqatxAZSbplQ4ZhX84i1fWkwDn19BlrPIv9i+kUxNYKxOKtweRuQ9tYkWbXpEl2kYPe02y79AGDOpAo01stAAAAABcGHgEJdwAHCwEAASEhARgMgIcAAA=="
        let data = try #require(Data(base64Encoded: fixtureB64))
        try data.write(to: f.root.appendingPathComponent("sample.7z"))

        let tool = WorkspaceArchiveTool(environment: f.environment)
        let listed = try await tool.execute(.init(action: "list", source: "sample.7z"), context: f.context)
        #expect(listed.summary.contains("format=7z"))
        #expect(listed.summary.contains("docs/a.txt"))

        let extracted = try await tool.execute(
            .init(action: "extract", source: "sample.7z", destinationDir: "out7z"),
            context: f.context
        )
        #expect(extracted.summary.contains("entries=2"))
        #expect(try f.read("out7z/docs/a.txt") == "seven content")
        #expect(try f.read("out7z/docs/sub/b.md") == "nested content")

        // 7z creation is honestly unavailable.
        await #expect(throws: WorkspaceToolError.self) {
            _ = try await tool.execute(
                .init(action: "create", source: "out7z", destinationFile: "x.7z"),
                context: f.context
            )
        }
        // rar reports an honest, actionable boundary.
        await #expect(throws: WorkspaceToolError.self) {
            _ = try await tool.execute(.init(action: "extract", source: "sample.7z", destinationDir: "y", format: "rar"), context: f.context)
        }
    }

    @Test("tar extraction skips traversal entries")
    func tarTraversalSafety() async throws {
        let f = try Fixture()
        var writer = TarArchiveWriter()
        try writer.addFile(name: "ok/good.txt", contents: Data("good".utf8))
        try writer.addFile(name: "../evil.txt", contents: Data("evil".utf8))
        try writer.finish().write(to: f.root.appendingPathComponent("evil.tar"))

        let tool = WorkspaceArchiveTool(environment: f.environment)
        let output = try await tool.execute(
            .init(action: "extract", source: "evil.tar", destinationDir: "safe"),
            context: f.context
        )
        #expect(output.summary.contains("entries=1"))
        #expect(output.summary.contains("skipped=1"))
        #expect(try f.read("safe/ok/good.txt") == "good")
        #expect(!f.exists("evil.txt"))
    }
}
