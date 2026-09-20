import Foundation
import FloeCore

// Build 211 Git crash repair verification: exercises the REAL production
// LocalGitService.repositoryRoot implementation (compiled from
// FloeAgent/Sources/FloeGit/LocalGitService.swift by run_git_review_harness.sh).
//
// The harness proves the bounded discovery contract with real libgit2:
//   1. a non-file URL is rejected before any filesystem probe;
//   2. no repository above the ownership boundary is discovered, while the
//      same workspace resolves when the boundary sits above the repository;
//   3. a repository (or `.git` file worktree marker) stays discoverable at
//      any depth below the boundary — there is no arbitrary ancestor cap;
//   4. a deep path without any repository terminates as nil and the snapshot
//      entry point reports not-a-repository instead of failing.
//
// Usage (from the worktree root):
//   HARNESS_SCRATCH="Local/Scratch/git-harness" \
//   FloeAgent/scripts/tests/ide_review/run_git_review_harness.sh \
//     FloeAgent/scripts/tests/ide_review/git_repair211_main.swift git-repair211

nonisolated(unsafe) var failures: [String] = []
nonisolated(unsafe) var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if condition { print("PASS  \(label)") } else { print("FAIL  \(label)"); failures.append(label) }
}

let service = LocalGitService()

func makeScratch(_ label: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("floe-repair211-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func testNonFileURLRejected() async {
    if let remote = URL(string: "https://example.invalid/repo") {
        check(await service.repositoryRoot(at: remote) == nil, "non-file URL rejected")
    }
}

func testOwnershipBoundary() async throws {
    let base = try makeScratch("boundary")
    defer { try? FileManager.default.removeItem(at: base) }

    // A real repository *above* the boundary.
    let repository = base.appendingPathComponent("outer", isDirectory: true)
    try FileManager.default.createDirectory(
        at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true
    )
    let boundary = repository.appendingPathComponent("boundary", isDirectory: true)
    var workspace = boundary
    for index in 0..<40 { workspace = workspace.appendingPathComponent("d\(index)", isDirectory: true) }
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

    check(await service.repositoryRoot(at: workspace, ownershipBoundary: boundary) == nil,
          "repository above the ownership boundary is not discovered")
    check(await service.repositoryRoot(at: workspace, ownershipBoundary: base)
              == repository.standardizedFileURL,
          "same workspace resolves when the boundary sits above the repository")

    // The boundary itself may be the repository (dotfiles-style home).
    try FileManager.default.createDirectory(
        at: boundary.appendingPathComponent(".git"), withIntermediateDirectories: true
    )
    check(await service.repositoryRoot(at: workspace, ownershipBoundary: boundary)
              == boundary.standardizedFileURL,
          "repository at the ownership boundary is still discovered")
}

func testDeepDiscovery() async throws {
    let base = try makeScratch("deep")
    defer { try? FileManager.default.removeItem(at: base) }

    // A repository 70 levels down (deeper than any ancestor cap) with the
    // workspace five levels below it: both must resolve through the real
    // production boundary (the user home on macOS, the app container on iOS).
    var repository = base.appendingPathComponent("repo", isDirectory: true)
    for index in 0..<70 { repository = repository.appendingPathComponent("r\(index)", isDirectory: true) }
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    _ = try await service.initialize(at: repository, initialBranch: "main")
    var workspace = repository
    for index in 0..<5 { workspace = workspace.appendingPathComponent("w\(index)", isDirectory: true) }
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

    check(await service.repositoryRoot(at: workspace) == repository.standardizedFileURL,
          "deep repository (70 levels) resolves from a nested workspace")
    let snapshot = try await service.snapshot(at: workspace)
    check(snapshot.isRepository && snapshot.repositoryRoot == repository.standardizedFileURL,
          "nested-workspace snapshot reports the deep repository root")

    // A deep path with no repository anywhere above it terminates as nil and
    // the snapshot entry point used by the crashing refresh returns
    // not-a-repository instead of failing.
    var empty = base.appendingPathComponent("empty", isDirectory: true)
    for index in 0..<70 { empty = empty.appendingPathComponent("e\(index)", isDirectory: true) }
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    check(await service.repositoryRoot(at: empty) == nil,
          "70-level tree without a repository terminates nil")
    let emptySnapshot = try await service.snapshot(at: empty)
    check(!emptySnapshot.isRepository, "snapshot of a deep non-repository path is not-a-repository")
}

func testWorktreeMarker() async throws {
    let base = try makeScratch("worktree")
    defer { try? FileManager.default.removeItem(at: base) }
    let worktree = base.appendingPathComponent("linked", isDirectory: true)
    let workspace = worktree.appendingPathComponent("src/sub", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try Data("gitdir: /elsewhere\n".utf8).write(to: worktree.appendingPathComponent(".git"))
    check(await service.repositoryRoot(at: workspace) == worktree.standardizedFileURL,
          ".git file (linked worktree/submodule) found from a nested workspace")
}

func testOrdinaryDiscovery() async throws {
    let repo = try makeScratch("repo")
    defer { try? FileManager.default.removeItem(at: repo) }
    _ = try await service.initialize(at: repo, initialBranch: "main")
    check(await service.repositoryRoot(at: repo) == repo.standardizedFileURL, "repository root found")
    let nested = repo.appendingPathComponent("a/b/c", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    check(await service.repositoryRoot(at: nested) == repo.standardizedFileURL,
          "nested workspace resolves to the repository root")
    let snap = try await service.snapshot(at: nested)
    check(snap.isRepository && snap.branch == "main", "snapshot from nested workspace")
}

func testSafeTermination() async {
    check(await service.repositoryRoot(at: URL(fileURLWithPath: "/")) == nil,
          "bare filesystem root terminates nil")
    check(await service.repositoryRoot(at: URL(fileURLWithPath: "/System")) == nil,
          "/System terminates nil")
    // `URL(fileURLWithPath: "")` is the current directory, so the pathless
    // file URL is the guard case: no path, no ancestor probe.
    if let pathless = URL(string: "file://") {
        check(await service.repositoryRoot(at: pathless) == nil,
              "pathless file URL terminates nil")
    }
}

func testIntactRepositoryAfterFix() async throws {
    let repo = try makeScratch("intact")
    defer { try? FileManager.default.removeItem(at: repo) }
    _ = try await service.initialize(at: repo, initialBranch: "main")
    let repoSnapshot = try await service.snapshot(at: repo)
    check(repoSnapshot.isRepository, "intact repository snapshot")
    check(repoSnapshot.repositoryRoot == repo.standardizedFileURL, "snapshot repositoryRoot")
}

@main
struct GitRepair211Harness {
    static func main() async {
        do {
            await testNonFileURLRejected()
            try await testOwnershipBoundary()
            try await testDeepDiscovery()
            try await testWorktreeMarker()
            try await testOrdinaryDiscovery()
            await testSafeTermination()
            try await testIntactRepositoryAfterFix()
        } catch {
            failures.append("unexpected error: \(error)")
            print("FAIL  unexpected error: \(error)")
        }
        print("\n\(checks - failures.count)/\(checks) checks passed")
        if !failures.isEmpty {
            print("FAILED: \(failures.count)")
            for failure in failures { print("  - \(failure)") }
            exit(1)
        }
        print("ALL GIT REPAIR 211 CHECKS PASSED")
    }
}
