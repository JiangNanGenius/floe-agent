// FloeWorkspaceTests — WorkspacePathGuard containment, symlink and secret
// exclusion, and size-cap behavior against a real temporary directory.
// See docs/ARCHITECTURE_AGENT_WORKSPACE.md §3.

import Foundation
import Testing
@testable import FloeWorkspace

@Suite("FloeWorkspace.WorkspacePathGuard")
struct WorkspacePathGuardTests {

    /// Creates a real temporary workspace root; cleaned up after the test.
    private func makeFixture() throws -> (root: URL, guardResolver: WorkspacePathGuard) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-guard-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let guardResolver = WorkspacePathGuard(rootURL: root)
        return (root, guardResolver)
    }

    private func cleanup(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Happy path

    @Test("Plain relative paths resolve inside the root")
    func relativePathResolves() throws {
        let (root, guardResolver) = try makeFixture()
        defer { cleanup(root) }
        let url = try guardResolver.resolve("src/main.swift")
        #expect(url.path.hasPrefix(guardResolver.rootURL.path + "/"))
        #expect(url.lastPathComponent == "main.swift")
    }

    @Test("Dot segments normalize without escaping")
    func dotSegmentsNormalize() throws {
        let (root, guardResolver) = try makeFixture()
        defer { cleanup(root) }
        let url = try guardResolver.resolve("src/../README.md")
        #expect(url.lastPathComponent == "README.md")
        #expect(url.deletingLastPathComponent().path == guardResolver.rootURL.path)
    }

    // MARK: Escapes

    @Test("../ traversal past the root throws escapesRoot")
    func dotDotEscapeRejected() throws {
        let (root, guardResolver) = try makeFixture()
        defer { cleanup(root) }
        #expect(throws: WorkspaceToolError.self) {
            _ = try guardResolver.resolve("../outside.txt")
        }
        do {
            _ = try guardResolver.resolve("../../etc/passwd")
            Issue.record("expected escapesRoot")
        } catch let error as WorkspaceToolError {
            #expect(error == .escapesRoot("../../etc/passwd"))
        }
    }

    @Test("Absolute paths are rejected")
    func absolutePathRejected() throws {
        let (root, guardResolver) = try makeFixture()
        defer { cleanup(root) }
        for path in ["/etc/passwd", "/tmp/x", "~/secret"] {
            #expect(throws: WorkspaceToolError.self) {
                _ = try guardResolver.resolve(path)
            }
        }
    }

    @Test("Empty path is rejected")
    func emptyPathRejected() throws {
        let (root, guardResolver) = try makeFixture()
        defer { cleanup(root) }
        #expect(throws: WorkspaceToolError.self) {
            _ = try guardResolver.resolve("")
        }
        #expect(throws: WorkspaceToolError.self) {
            _ = try guardResolver.resolve("   ")
        }
    }

    @Test("Symlink pointing outside the root throws escapesRoot")
    func symlinkEscapeRejected() throws {
        let (root, guardResolver) = try makeFixture()
        defer { cleanup(root) }
        // Real outside target.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-outside-\(UUID().uuidString)")
        try "top secret".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        let link = root.appendingPathComponent("escape-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        do {
            _ = try guardResolver.resolve("escape-link")
            Issue.record("expected escapesRoot for symlink escape")
        } catch let error as WorkspaceToolError {
            guard case .escapesRoot = error else {
                Issue.record("expected escapesRoot, got \(error)")
                return
            }
        }
    }

    @Test("Symlink inside the root resolves to the real file")
    func internalSymlinkAllowed() throws {
        let (root, guardResolver) = try makeFixture()
        defer { cleanup(root) }
        let real = root.appendingPathComponent("real.txt")
        try "hello".write(to: real, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let resolved = try guardResolver.resolve("alias.txt")
        #expect(resolved.lastPathComponent == "real.txt")
    }

    @Test("Missing output descendants cannot conceal a symlink escape")
    func missingOutputUnderExternalSymlinkRejected() throws {
        let (root, guardResolver) = try makeFixture()
        defer { cleanup(root) }
        let outside = root.deletingLastPathComponent().appendingPathComponent("floe-outside-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        defer { cleanup(outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("GeneratedImages"), withDestinationURL: outside)
        #expect(throws: WorkspaceToolError.self) { try guardResolver.resolve("GeneratedImages/Apple/new-run/image.png") }
        #expect(throws: WorkspaceToolError.self) { try guardResolver.assertWritable(root.appendingPathComponent("GeneratedImages/Apple/new-run/image.png")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test("Dangling links and cycles cannot authorize a new output")
    func danglingExternalLinkAndCycleRejected() throws {
        let (root, guardResolver) = try makeFixture()
        defer { cleanup(root) }
        let outside = root.deletingLastPathComponent().appendingPathComponent("floe-missing-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("dangling"), withDestinationURL: outside)
        #expect(throws: WorkspaceToolError.self) { try guardResolver.resolve("dangling/new/image.png") }
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("cycle-a").path, withDestinationPath: "cycle-b")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("cycle-b").path, withDestinationPath: "cycle-a")
        #expect(throws: WorkspaceToolError.self) { try guardResolver.resolve("cycle-a/new.png") }
    }

    @Test("Internal directory links retain contained new-output semantics")
    func internalDirectoryLinkWithNewDescendantsAllowed() throws {
        let (root, guardResolver) = try makeFixture()
        defer { cleanup(root) }
        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("alias").path, withDestinationPath: "real")
        let result = try guardResolver.resolve("alias/missing/new.png")
        #expect(result.path == guardResolver.rootURL.appendingPathComponent("real/missing/new.png").path)
        try guardResolver.assertWritable(result)
        #expect(!FileManager.default.fileExists(atPath: real.appendingPathComponent("missing").path))
    }

    // MARK: Secrets

    @Test("Secret-file exclusion list is enforced")
    func secretFilesRejected() throws {
        let (root, guardResolver) = try makeFixture()
        defer { cleanup(root) }
        let secretPaths = [
            ".env", ".env.local", "certs/server.pem", "private.key",
            "id_rsa", "id_ed25519",
            ".ssh/config", ".aws/credentials", ".netrc", "app.keystore",
            "cert.p12", ".git/config"
        ]
        for path in secretPaths {
            do {
                _ = try guardResolver.resolve(path)
                Issue.record("expected secretFile for \(path)")
            } catch let error as WorkspaceToolError {
                guard case .secretFile = error else {
                    Issue.record("expected secretFile for \(path), got \(error)")
                    continue
                }
            }
        }
    }

    @Test("Non-secret lookalikes are allowed")
    func nonSecretAllowed() throws {
        let (root, guardResolver) = try makeFixture()
        defer { cleanup(root) }
        _ = try guardResolver.resolve("environment.md")
        _ = try guardResolver.resolve("keys.txt")
        _ = try guardResolver.resolve("src/config.swift")
    }

    // MARK: Size caps

    @Test("Existing file larger than maxReadBytes throws tooLarge")
    func readSizeCap() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-guard-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { cleanup(root) }
        let guardResolver = WorkspacePathGuard(rootURL: root, maxReadBytes: 16, maxWriteBytes: 8)

        let big = root.appendingPathComponent("big.txt")
        try String(repeating: "x", count: 64).write(to: big, atomically: true, encoding: .utf8)
        let resolved = try guardResolver.resolve("big.txt")
        do {
            try guardResolver.assertReadableSize(resolved)
            Issue.record("expected tooLarge")
        } catch let error as WorkspaceToolError {
            guard case .tooLarge(let limit) = error else {
                Issue.record("expected tooLarge, got \(error)")
                return
            }
            #expect(limit == 16)
        }

        // Under the cap passes.
        let small = root.appendingPathComponent("small.txt")
        try "hi".write(to: small, atomically: true, encoding: .utf8)
        try guardResolver.assertReadableSize(try guardResolver.resolve("small.txt"))
    }

    @Test("Write payload over maxWriteBytes throws tooLarge")
    func writeSizeCap() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-guard-wcap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { cleanup(root) }
        let guardResolver = WorkspacePathGuard(rootURL: root, maxReadBytes: 16, maxWriteBytes: 8)

        try guardResolver.assertWritableSize(bytes: 8)
        #expect(throws: WorkspaceToolError.self) {
            try guardResolver.assertWritableSize(bytes: 9)
        }
    }

    @Test("Structured error summary carries a stable code")
    func structuredSummary() {
        let summary = WorkspaceToolError.conflict(expected: "a", actual: "b").structuredSummary
        #expect(summary.contains(#""code":"conflict""#))
        #expect(summary.contains(#""expected":"a""#))
        #expect(WorkspaceToolError.tooLarge(limit: 42).structuredSummary.contains(#""limit":"42""#))
    }

    @Test("An export write budget retains mounts and all path exclusions")
    func exportWriteBudgetKeepsContainment() throws {
        let (root, _) = try makeFixture()
        defer { cleanup(root) }
        let mounted = root.appendingPathComponent("chosen-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: mounted, withIntermediateDirectories: true)
        let original = WorkspacePathGuard(rootURL: root, maxReadBytes: 16,
                                          maxWriteBytes: 8, mounts: ["chosen": mounted])
        let export = original.withWriteLimit(32)
        #expect(export.maxReadBytes == 16)
        #expect(original.maxWriteBytes == 8)
        try export.assertWritableSize(bytes: 32)
        #expect(throws: WorkspaceToolError.self) { try export.assertWritableSize(bytes: 33) }
        #expect(throws: WorkspaceToolError.self) { try original.assertWritableSize(bytes: 9) }
        #expect(try export.resolve("Mounts/chosen/model.zip") == original.resolve("Mounts/chosen/model.zip"))
        #expect(throws: WorkspaceToolError.self) { try export.resolve("../outside.zip") }
        #expect(throws: WorkspaceToolError.self) { try export.resolve(".env") }
    }
}
