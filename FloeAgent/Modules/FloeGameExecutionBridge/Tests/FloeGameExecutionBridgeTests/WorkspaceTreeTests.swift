// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeGameCore
@testable import FloeGameExecutionBridge

@Suite("bounded workspace staging")
struct WorkspaceTreeTests {
    @Test("manifest matches the CI canonical digest and excludes .git/.floe/out")
    func canonicalDigest() throws {
        let temp = try ExecutionTemporaryDirectory(); defer { temp.cleanup() }
        try temp.write("index.html", "<!doctype html><title>t</title>")
        try temp.write("assets/game.js", "console.log(1)")
        try temp.write(".git/config", "admin")
        try temp.write("out/stale.js", "stale")
        try temp.write(".floe/cache", "cache")
        let manifest = try GameWorkspaceTree.manifest(rootURL: temp.url)
        #expect(manifest.files.map(\.path.value) == ["assets/game.js", "index.html"])
        let rows = manifest.files.map {
            "\($0.path.value):\($0.sha256):\($0.bytes):\($0.executable ? "1" : "0")"
        }.sorted()
        let expected = GameDigest.sha256(Data(rows.joined(separator: "\n").utf8))
        #expect(manifest.digest == expected)
    }

    @Test("copy and publish preserve bytes and refuse a non-empty output")
    func copyAndPublish() throws {
        let temp = try ExecutionTemporaryDirectory(); defer { temp.cleanup() }
        let source = temp.url.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try temp.write("source/index.html", "<!doctype html>")
        let copy = temp.url.appendingPathComponent("copy")
        let manifest = try GameWorkspaceTree.copyTree(from: source, to: copy)
        #expect(manifest.files.count == 1)
        let output = temp.url.appendingPathComponent("output")
        try GameWorkspaceTree.publishContents(
            of: copy, to: output, expectedEntry: try GameRelativePath("index.html"))
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("index.html").path))
        #expect(throws: GameExecutionError.self) {
            try GameWorkspaceTree.publishContents(
                of: copy, to: output, expectedEntry: try GameRelativePath("index.html"))
        }
    }

    @Test("symlinks are refused instead of copied")
    func rejectsSymlink() throws {
        let temp = try ExecutionTemporaryDirectory(); defer { temp.cleanup() }
        try temp.write("index.html", "ok")
        try FileManager.default.createSymbolicLink(
            at: temp.url.appendingPathComponent("link"),
            withDestinationURL: temp.url.appendingPathComponent("index.html"))
        #expect(throws: GameExecutionError.self) {
            try GameWorkspaceTree.manifest(rootURL: temp.url)
        }
    }
}
