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

    @Test("repositoryRoot walks up to a repository and reports nil outside one")
    func repositoryRootDiscoversAncestors() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeGitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = LocalGitService()

        // Not a repository: no ancestor of the temp directory is a repo.
        #expect(await git.repositoryRoot(at: root) == nil)

        _ = try await git.initialize(
            at: root,
            authorName: "Floe Tests",
            authorEmail: "floe-tests@example.invalid"
        )

        // The repository root itself.
        #expect(await git.repositoryRoot(at: root) == root.standardizedFileURL)

        // A workspace nested inside the repository resolves to the repo root,
        // so source control stays visible instead of "not a repository".
        let nested = root.appendingPathComponent("sub/dir", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        #expect(await git.repositoryRoot(at: nested) == root.standardizedFileURL)

        // The snapshot taken from the nested workspace is a repository whose
        // reported root is the real repository root.
        let snapshot = try await git.snapshot(at: nested)
        #expect(snapshot.isRepository)
        #expect(snapshot.repositoryRoot == root.standardizedFileURL)
    }

    @Test("local init works without any remote author identity")
    func initializeWithoutAuthor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeGitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = LocalGitService()

        // No GitHub sign-in and no author: initializing a local repository
        // must still succeed and report the intended unborn branch.
        let initialized = try await git.initialize(at: root)
        #expect(initialized.isRepository)
        #expect(initialized.branch == "main")
        #expect(initialized.recentCommits.isEmpty)
        #expect(initialized.changes.isEmpty)
        // No identity was configured at init time; the first commit applies
        // the commit-time identity instead.
        let snapshot = try await git.snapshot(at: root)
        #expect(snapshot.branch == "main")
    }

    @Test("initializing over an existing repository never re-points its HEAD")
    func initializeIsIdempotentOnExistingRepository() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeGitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = LocalGitService()

        _ = try await git.initialize(at: root, initialBranch: "main")
        try Data("one\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        try await git.stageAll(at: root)
        _ = try await git.commit(
            at: root, message: "First",
            authorName: "Floe Tests", authorEmail: "floe-tests@example.invalid"
        )

        // A second initialize (e.g. a repeated tool call) must leave the
        // existing branch, config and history untouched.
        let again = try await git.initialize(at: root, initialBranch: "trunk")
        #expect(again.isRepository)
        #expect(again.branch == "main")
        #expect(again.recentCommits.count == 1)
        #expect(again.changes.isEmpty)
    }

    @Test("commit keeps a repository identity that already exists")
    func commitPreservesExistingIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeGitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = LocalGitService()

        _ = try await git.initialize(at: root)
        try Data("one\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        try await git.stageAll(at: root)
        // A commit-time identity is written because the repository has none.
        _ = try await git.commit(
            at: root, message: "First",
            authorName: "Floe Tests", authorEmail: "floe-tests@example.invalid"
        )

        // Simulate a user-supplied identity (e.g. edited `.git/config`).
        let configURL = root.appendingPathComponent(".git/config")
        var config = try String(contentsOf: configURL, encoding: .utf8)
        config = config
            .replacingOccurrences(of: "name = Floe Tests", with: "name = Custom User")
            .replacingOccurrences(of: "email = floe-tests@example.invalid", with: "email = user@example.invalid")
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        try Data("one\ntwo\n".utf8).write(to: root.appendingPathComponent("a.txt"))
        try await git.stageAll(at: root)
        let commit = try await git.commit(
            at: root, message: "Second",
            authorName: "Floe Tests", authorEmail: "floe-tests@example.invalid"
        )
        #expect(commit.author == "Custom User")
        let snapshot = try await git.snapshot(at: root)
        #expect(snapshot.recentCommits.first?.author == "Custom User")
    }

    @Test("repositoryRoot rejects non-file URLs and stops at the ownership boundary")
    func repositoryRootOwnershipBoundary() async throws {
        let git = LocalGitService()

        // A non-file URL has no meaningful ancestors and must be rejected
        // instead of being fed into the filesystem walk.
        if let remote = URL(string: "https://example.invalid/repo") {
            #expect(await git.repositoryRoot(at: remote) == nil)
        }

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeGitTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // An ordinary repository *above* the boundary must not be reported:
        // the boundary is the highest directory a workspace may resolve to.
        let repository = base.appendingPathComponent("outer", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        let boundary = repository.appendingPathComponent("boundary", isDirectory: true)
        var workspace = boundary
        for index in 0..<40 {
            workspace = workspace.appendingPathComponent("d\(index)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        #expect(await git.repositoryRoot(at: workspace, ownershipBoundary: boundary) == nil)
        // The same workspace resolves once the boundary sits above the repo.
        #expect(await git.repositoryRoot(at: workspace, ownershipBoundary: base)
            == repository.standardizedFileURL)

        // The boundary itself may be the repository (a dotfiles home), and it
        // is still found because the boundary is checked before stopping.
        try FileManager.default.createDirectory(
            at: boundary.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        #expect(await git.repositoryRoot(at: workspace, ownershipBoundary: boundary)
            == boundary.standardizedFileURL)
    }

    @Test("repositoryRoot keeps deep repositories and worktrees discoverable")
    func repositoryRootPreservesDeepDiscovery() async throws {
        let git = LocalGitService()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeGitTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // A repository 70 levels down (deeper than any ancestor cap) with the
        // workspace five levels below it is still discovered and snapshotted.
        var repository = base.appendingPathComponent("repo", isDirectory: true)
        for index in 0..<70 {
            repository = repository.appendingPathComponent("r\(index)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        _ = try await git.initialize(at: repository, initialBranch: "main")
        var workspace = repository
        for index in 0..<5 {
            workspace = workspace.appendingPathComponent("w\(index)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        #expect(await git.repositoryRoot(at: workspace) == repository.standardizedFileURL)
        let snapshot = try await git.snapshot(at: workspace)
        #expect(snapshot.isRepository)
        #expect(snapshot.repositoryRoot == repository.standardizedFileURL)

        // A deep path with no repository anywhere above it terminates as nil
        // (the crashing refresh path) instead of failing or looping.
        var empty = base.appendingPathComponent("empty", isDirectory: true)
        for index in 0..<70 {
            empty = empty.appendingPathComponent("e\(index)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(await git.repositoryRoot(at: empty) == nil)
        let emptySnapshot = try await git.snapshot(at: empty)
        #expect(!emptySnapshot.isRepository)

        // A `.git` *file* (linked worktree or submodule) is still a marker.
        let worktree = base.appendingPathComponent("worktree/sub", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Data("gitdir: /elsewhere\n".utf8)
            .write(to: worktree.deletingLastPathComponent().appendingPathComponent(".git"))
        #expect(await git.repositoryRoot(at: worktree)
            == worktree.deletingLastPathComponent().standardizedFileURL)
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
