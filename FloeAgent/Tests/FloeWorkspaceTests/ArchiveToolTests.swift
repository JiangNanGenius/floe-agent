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
            .init(action: "create", source: "project", destination: "pack.zip"),
            context: f.context
        )
        #expect(created.summary.contains("entries=2"))
        #expect(f.exists("pack.zip"))

        let listed = try await tool.execute(.init(action: "list", source: "pack.zip"), context: f.context)
        #expect(listed.summary.contains("project/a.txt"), "list was: \(listed.summary)")
        #expect(listed.summary.contains("project/nested/b.md"))

        let extracted = try await tool.execute(
            .init(action: "extract", source: "pack.zip", destination: "unpacked"),
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
            .init(action: "create", source: "note.txt", destination: "note.zip"),
            context: f.context
        )
        #expect(first.summary.contains("entries=1"))
        await #expect(throws: WorkspaceToolError.self) {
            _ = try await tool.execute(
                .init(action: "create", source: "note.txt", destination: "note.zip"),
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
            .init(action: "extract", source: "hostile.zip", destination: "out"),
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
            try tool.validate(.init(action: "create", source: "/etc/passwd", destination: "x.zip"))
        }
        #expect(throws: WorkspaceToolError.self) {
            try tool.validate(.init(action: "extract", source: "a.zip"))
        }
    }
}
