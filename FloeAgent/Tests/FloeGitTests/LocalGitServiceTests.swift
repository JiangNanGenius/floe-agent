import Foundation
import Testing
@testable import FloeGit

@Suite("Native local Git")
struct LocalGitServiceTests {
    @Test("initialize, stage, commit, diff and branch without shell Git")
    func localLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeGitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let git = LocalGitService()
        let empty = try await git.snapshot(at: root)
        #expect(!empty.isRepository)

        let initialized = try await git.initialize(
            at: root,
            authorName: "Floe Tests",
            authorEmail: "floe-tests@example.invalid"
        )
        #expect(initialized.isRepository)
        #expect(initialized.branch == "main")

        let file = root.appendingPathComponent("README.md")
        try Data("first\n".utf8).write(to: file)
        let untracked = try await git.snapshot(at: root)
        #expect(untracked.changes.contains { $0.path == "README.md" && $0.kind == .untracked })

        try await git.stageAll(at: root)
        let commit = try await git.commit(
            at: root,
            message: "Initial commit",
            authorName: "Floe Tests",
            authorEmail: "floe-tests@example.invalid"
        )
        #expect(commit.message == "Initial commit")
        #expect((try await git.snapshot(at: root)).changes.isEmpty)

        try Data("first\nsecond\n".utf8).write(to: file)
        let diff = try await git.diff(at: root, path: "README.md")
        #expect(diff.contains("+second"))

        try await git.stage(paths: ["README.md"], at: root)
        _ = try await git.commit(
            at: root,
            message: "Update readme",
            authorName: "Floe Tests",
            authorEmail: "floe-tests@example.invalid"
        )
        try await git.createBranch(at: root, name: "feature/lightweight-editor")
        let branched = try await git.snapshot(at: root)
        #expect(branched.branch == "feature/lightweight-editor")
        #expect(branched.recentCommits.count == 2)
    }

    @Test("rejects paths and branches that escape or rewrite repository metadata")
    func validatesRepositoryInputs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeGitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = LocalGitService()
        _ = try await git.initialize(
            at: root,
            authorName: "Floe Tests",
            authorEmail: "floe-tests@example.invalid"
        )

        await #expect(throws: (any Error).self) {
            try await git.stage(paths: ["../outside"], at: root)
        }
        await #expect(throws: (any Error).self) {
            try await git.createBranch(at: root, name: "../bad")
        }
    }
}
