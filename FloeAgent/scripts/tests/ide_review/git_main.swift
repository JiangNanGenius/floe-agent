// Independent behavior harness for the Build191 IDE Git patch
// (FloeAgent/Sources/FloeGit/LocalGitService.swift + GitModels.swift).
//
// Compiles the real production sources against real libgit2 (cached C object
// from the local SwiftPM build) and exercises merge / conflict / unstage /
// discard / staged-diff on real temporary repositories. No SwiftPM build, no
// FloeApp, no simulator, no network.
//
// Run via tests/build_and_run.sh.

import Foundation
import FloeCore
import libgit2

// MARK: - tiny check framework

nonisolated(unsafe) var failures: [String] = []
nonisolated(unsafe) var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if condition {
        print("PASS  \(label)")
    } else {
        print("FAIL  \(label)")
        failures.append(label)
    }
}

func checkEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) {
    check(lhs == rhs, "\(label) (got \(lhs), want \(rhs))")
}

// MARK: - helpers

let service = LocalGitService()
let authorName = "Review"
let authorEmail = "review@floe.dev"

func makeRepo(_ label: String) async throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("floe-review-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    _ = try await service.initialize(at: url, authorName: authorName, authorEmail: authorEmail, initialBranch: "main")
    return url
}

func cleanUp(_ root: URL) {
    try? FileManager.default.removeItem(at: root)
}

func write(_ root: URL, _ path: String, _ text: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url, options: .atomic)
}

func read(_ root: URL, _ path: String) throws -> String {
    String(decoding: try Data(contentsOf: root.appendingPathComponent(path)), as: UTF8.self)
}

func exists(_ root: URL, _ path: String) -> Bool {
    FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
}

@discardableResult
func commitAll(_ root: URL, _ message: String) async throws -> String {
    try await service.stageAll(at: root)
    let commit = try await service.commit(at: root, message: message,
                                          authorName: authorName, authorEmail: authorEmail)
    return commit.oid
}

struct HeadInfo {
    let oid: String
    let parents: Int
    let detached: Bool
}

func headInfo(_ root: URL) throws -> HeadInfo {
    var repository: OpaquePointer?
    guard git_repository_open(&repository, root.path) >= 0, let repository else {
        throw FloeError.internalError("cannot open repo")
    }
    defer { git_repository_free(repository) }
    var oid = git_oid()
    let status = git_reference_name_to_id(&oid, repository, "HEAD")
    guard status >= 0 else { throw FloeError.internalError("no HEAD") }
    var buffer = [CChar](repeating: 0, count: 41)
    git_oid_fmt(&buffer, &oid)
    var commit: OpaquePointer?
    guard git_commit_lookup(&commit, repository, &oid) >= 0, let commit else {
        throw FloeError.internalError("no commit object")
    }
    defer { git_commit_free(commit) }
    return HeadInfo(oid: String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self),
                    parents: Int(git_commit_parentcount(commit)),
                    detached: git_repository_head_detached(repository) == 1)
}

func change(_ root: URL, _ path: String) async throws -> GitFileChange? {
    let snapshot = try await service.snapshot(at: root)
    return snapshot.changes.first { $0.path == path }
}

func expectThrows(_ label: String, _ body: () async throws -> Void) async {
    do {
        try await body()
        check(false, label)
    } catch {
        check(true, label)
    }
}

// MARK: - tests

func testFastForward() async throws {
    let root = try await makeRepo("ff")
    defer { cleanUp(root) }
    try write(root, "a.txt", "one")
    let first = try await commitAll(root, "c1")
    _ = try await service.createBranch(at: root, name: "feature", switchToBranch: false)
    try await service.switchBranch(at: root, name: "feature")
    try write(root, "b.txt", "feature")
    let featureCommit = try await commitAll(root, "c2")
    try await service.switchBranch(at: root, name: "main")

    let outcome = try await service.mergeRef(at: root, refName: "refs/heads/feature",
                                             authorName: authorName, authorEmail: authorEmail)
    checkEqual(outcome.result, GitMergeOutcome.Result.fastForward, "fast-forward: outcome")
    let head = try headInfo(root)
    checkEqual(head.oid, featureCommit, "fast-forward: HEAD moved to the merged branch")
    check(head.oid != first, "fast-forward: HEAD is not the old commit")
    check(exists(root, "b.txt"), "fast-forward: merged file checked out")
    let snapshot = try await service.snapshot(at: root)
    checkEqual(snapshot.changes.count, 0, "fast-forward: clean tree after update")
    checkEqual(snapshot.branch, "main", "fast-forward: current branch is still main")
}

func testMergeCommit() async throws {
    let root = try await makeRepo("merge")
    defer { cleanUp(root) }
    try write(root, "a.txt", "one")
    _ = try await commitAll(root, "c1")
    _ = try await service.createBranch(at: root, name: "feature", switchToBranch: false)

    try write(root, "c.txt", "main side")
    _ = try await commitAll(root, "c3 main")
    try await service.switchBranch(at: root, name: "feature")
    try write(root, "d.txt", "feature side")
    let featureCommit = try await commitAll(root, "c4 feature")
    try await service.switchBranch(at: root, name: "main")

    let outcome = try await service.mergeRef(at: root, refName: "refs/heads/feature",
                                             authorName: authorName, authorEmail: authorEmail)
    checkEqual(outcome.result, GitMergeOutcome.Result.merged, "merge commit: outcome")
    let head = try headInfo(root)
    checkEqual(head.parents, 2, "merge commit: two parents")
    check(head.oid != featureCommit, "merge commit: new commit created")
    check(exists(root, "c.txt") && exists(root, "d.txt"), "merge commit: both sides present")
    let merging = try await service.isMerging(at: root)
    check(!merging, "merge commit: merge state cleaned up")
    let snapshot = try await service.snapshot(at: root)
    checkEqual(snapshot.changes.count, 0, "merge commit: clean tree")
}

func testConflictAndResolve() async throws {
    let root = try await makeRepo("conflict")
    defer { cleanUp(root) }
    try write(root, "a.txt", "base")
    _ = try await commitAll(root, "c1")
    _ = try await service.createBranch(at: root, name: "feature", switchToBranch: false)
    try await service.switchBranch(at: root, name: "feature")
    try write(root, "a.txt", "feature")
    _ = try await commitAll(root, "c2")
    try await service.switchBranch(at: root, name: "main")
    try write(root, "a.txt", "main")
    let mainCommit = try await commitAll(root, "c3")

    let conflict = try await service.mergeRef(at: root, refName: "refs/heads/feature",
                                              authorName: authorName, authorEmail: authorEmail)
    checkEqual(conflict.result, GitMergeOutcome.Result.conflicts, "conflict: outcome is conflicts")
    checkEqual(conflict.conflictedPaths, ["a.txt"], "conflict: conflicted paths")
    let mergingDuring = try await service.isMerging(at: root)
    check(mergingDuring, "conflict: repository is in merge state")
    let marked = try read(root, "a.txt")
    check(marked.contains("<<<<<<<") || marked.contains("======="), "conflict: markers written for resolution")
    let headDuring = try headInfo(root)
    checkEqual(headDuring.oid, mainCommit, "conflict: HEAD still on our side")
    checkEqual(headDuring.parents, 1, "conflict: no merge commit yet")

    let resolved = try await service.resolveConflict(at: root, path: "a.txt", content: "resolved",
                                                     authorName: authorName, authorEmail: authorEmail)
    checkEqual(resolved.result, GitMergeOutcome.Result.merged, "resolve: outcome merged")
    checkEqual(try read(root, "a.txt"), "resolved", "resolve: content written")
    let headAfter = try headInfo(root)
    checkEqual(headAfter.parents, 2, "resolve: merge commit has two parents")
    check(!(try await service.isMerging(at: root)), "resolve: merge state cleaned up")
    let snapshot = try await service.snapshot(at: root)
    checkEqual(snapshot.changes.count, 0, "resolve: clean tree")
}

func testAbortMerge() async throws {
    let root = try await makeRepo("abort")
    defer { cleanUp(root) }
    try write(root, "a.txt", "base")
    _ = try await commitAll(root, "c1")
    _ = try await service.createBranch(at: root, name: "feature", switchToBranch: false)
    try await service.switchBranch(at: root, name: "feature")
    try write(root, "a.txt", "feature")
    _ = try await commitAll(root, "c2")
    try await service.switchBranch(at: root, name: "main")
    try write(root, "a.txt", "main")
    let mainCommit = try await commitAll(root, "c3")

    let conflict = try await service.mergeRef(at: root, refName: "refs/heads/feature",
                                              authorName: authorName, authorEmail: authorEmail)
    checkEqual(conflict.result, GitMergeOutcome.Result.conflicts, "abort: conflict raised")
    try await service.abortMerge(at: root)
    check(!(try await service.isMerging(at: root)), "abort: merge state cleared")
    let head = try headInfo(root)
    checkEqual(head.oid, mainCommit, "abort: HEAD restored")
    checkEqual(head.parents, 1, "abort: no merge commit")
    checkEqual(try read(root, "a.txt"), "main", "abort: working tree restored to our side")
}

func testUnstage() async throws {
    let root = try await makeRepo("unstage")
    defer { cleanUp(root) }
    try write(root, "a.txt", "one")
    _ = try await commitAll(root, "c1")

    try write(root, "new.txt", "brand new")
    try await service.stage(paths: ["new.txt"], at: root)
    var entry = try await change(root, "new.txt")
    checkEqual(entry?.staged, true, "unstage: new file is staged")
    checkEqual(entry?.kind, GitChangeKind.added, "unstage: new file reported added")

    try await service.unstage(paths: ["new.txt"], at: root)
    entry = try await change(root, "new.txt")
    checkEqual(entry?.staged, false, "unstage: new file no longer staged")
    checkEqual(entry?.kind, GitChangeKind.untracked, "unstage: new file back to untracked")
    check(exists(root, "new.txt"), "unstage: working tree file preserved")

    try write(root, "a.txt", "two")
    try await service.stage(paths: ["a.txt"], at: root)
    entry = try await change(root, "a.txt")
    checkEqual(entry?.staged, true, "unstage: modified file staged")
    try await service.unstage(paths: ["a.txt"], at: root)
    entry = try await change(root, "a.txt")
    checkEqual(entry?.staged, false, "unstage: modified file unstaged")
    checkEqual(try read(root, "a.txt"), "two", "unstage: working tree kept the edit")
}

func testUnstageUnbornHead() async throws {
    let root = try await makeRepo("unborn")
    defer { cleanUp(root) }
    try write(root, "first.txt", "draft")
    try await service.stage(paths: ["first.txt"], at: root)
    var entry = try await change(root, "first.txt")
    checkEqual(entry?.staged, true, "unborn: staged before first commit")
    try await service.unstage(paths: ["first.txt"], at: root)
    entry = try await change(root, "first.txt")
    checkEqual(entry?.staged, false, "unborn: unstaged without a HEAD commit")
    checkEqual(entry?.kind, GitChangeKind.untracked, "unborn: file is untracked again")
}

func testStagedDiff() async throws {
    let root = try await makeRepo("diff")
    defer { cleanUp(root) }
    try write(root, "a.txt", "one\n")
    _ = try await commitAll(root, "c1")
    try write(root, "a.txt", "one\ntwo\n")
    try await service.stage(paths: ["a.txt"], at: root)
    let staged = try await service.diffStaged(at: root)
    check(staged.contains("+two"), "staged diff: contains staged line")
    check(staged.contains("a.txt"), "staged diff: names the file")
    try await service.unstage(paths: ["a.txt"], at: root)
    let afterUnstage = try await service.diffStaged(at: root)
    checkEqual(afterUnstage, "", "staged diff: empty after unstage")
    let unstaged = try await service.diff(at: root, path: "a.txt")
    check(unstaged.contains("+two"), "working diff: still shows the unstaged edit")
}

func testDiscard() async throws {
    let root = try await makeRepo("discard")
    defer { cleanUp(root) }
    try write(root, "a.txt", "one")
    _ = try await commitAll(root, "c1")
    try write(root, "a.txt", "two")
    try write(root, "note.txt", "untracked body")

    let outcome = try await service.discard(paths: ["a.txt", "note.txt"], at: root)
    checkEqual(outcome.discardedPaths.sorted(), ["a.txt", "note.txt"], "discard: reported paths")
    checkEqual(try read(root, "a.txt"), "one", "discard: tracked file restored from index")
    check(!exists(root, "note.txt"), "discard: untracked file removed")
    guard let recovery = outcome.recoveryPath else {
        check(false, "discard: recovery copy created")
        return
    }
    check(FileManager.default.fileExists(atPath: recovery), "discard: recovery copy exists")
    let recoveredTracked = String(decoding: try Data(contentsOf: URL(fileURLWithPath: recovery).appendingPathComponent("a.txt")), as: UTF8.self)
    let recoveredUntracked = String(decoding: try Data(contentsOf: URL(fileURLWithPath: recovery).appendingPathComponent("note.txt")), as: UTF8.self)
    checkEqual(recoveredTracked, "two", "discard: recovery holds the lost tracked bytes")
    checkEqual(recoveredUntracked, "untracked body", "discard: recovery holds the removed untracked bytes")
    let snapshot = try await service.snapshot(at: root)
    checkEqual(snapshot.changes.count, 0, "discard: working tree clean")
    check(recovery.hasPrefix(root.appendingPathComponent(".git/floe-recovery").path), "discard: recovery lives under .git")

    // Deleted tracked file is restored too.
    try FileManager.default.removeItem(at: root.appendingPathComponent("a.txt"))
    _ = try await service.discard(paths: ["a.txt"], at: root)
    checkEqual(try read(root, "a.txt"), "one", "discard: deleted tracked file restored")
}

func testPathSafety() async throws {
    let root = try await makeRepo("safety")
    defer { cleanUp(root) }
    try write(root, "a.txt", "one")
    _ = try await commitAll(root, "c1")

    await expectThrows("safety: discard rejects ../escape") {
        _ = try await service.discard(paths: ["../escape.txt"], at: root)
    }
    await expectThrows("safety: discard rejects absolute path") {
        _ = try await service.discard(paths: ["/tmp/escape.txt"], at: root)
    }
    await expectThrows("safety: discard rejects .git") {
        _ = try await service.discard(paths: [".git/config"], at: root)
    }
    await expectThrows("safety: unstage rejects traversal") {
        try await service.unstage(paths: ["../escape.txt"], at: root)
    }
    await expectThrows("safety: unstage rejects absolute path") {
        try await service.unstage(paths: ["/tmp/escape.txt"], at: root)
    }
    await expectThrows("safety: merge rejects unknown ref") {
        _ = try await service.mergeRef(at: root, refName: "refs/heads/missing",
                                       authorName: authorName, authorEmail: authorEmail)
    }
    await expectThrows("safety: pull merge rejects branch without upstream") {
        _ = try await service.pullMerge(at: root, token: nil,
                                        authorName: authorName, authorEmail: authorEmail)
    }
    check(exists(root, "a.txt"), "safety: workspace intact after refusals")
}

func testDiscardStaged() async throws {
    let root = try await makeRepo("discard-staged")
    defer { cleanUp(root) }
    try write(root, "a.txt", "one")
    _ = try await commitAll(root, "c1")

    // Staged addition: includeStaged discards the index entry and the file.
    try write(root, "new.txt", "addition")
    try await service.stage(paths: ["new.txt"], at: root)
    let addOutcome = try await service.discard(paths: ["new.txt"], at: root, includeStaged: true)
    check(!exists(root, "new.txt"), "discard staged: added file removed")
    var changes = try await service.snapshot(at: root).changes
    checkEqual(changes.count, 0, "discard staged: index clean after discarding addition")
    if let recovery = addOutcome.recoveryPath {
        let worktreeCopy = URL(fileURLWithPath: recovery).appendingPathComponent("new.txt")
        let indexCopy = URL(fileURLWithPath: recovery).appendingPathComponent("new.txt.staged")
        check(FileManager.default.fileExists(atPath: worktreeCopy.path), "discard staged: worktree bytes recovered")
        check(FileManager.default.fileExists(atPath: indexCopy.path), "discard staged: index bytes recovered")
    } else {
        check(false, "discard staged: recovery folder reported")
    }

    // Partially staged modification: worktree-only discard keeps the staged part.
    try write(root, "a.txt", "staged-version")
    try await service.stage(paths: ["a.txt"], at: root)
    try write(root, "a.txt", "worktree-version")
    _ = try await service.discard(paths: ["a.txt"], at: root, includeStaged: false)
    checkEqual(try read(root, "a.txt"), "staged-version",
               "discard unstaged: restored from index, staged content kept")
    var entry = try await change(root, "a.txt")
    checkEqual(entry?.staged, true, "discard unstaged: staged state preserved")

    // Full revert of the staged modification.
    _ = try await service.discard(paths: ["a.txt"], at: root, includeStaged: true)
    checkEqual(try read(root, "a.txt"), "one", "discard staged: reverted to HEAD")
    changes = try await service.snapshot(at: root).changes
    checkEqual(changes.count, 0, "discard staged: clean after full revert")

    // Staged deletion: discarding restores the HEAD content.
    try FileManager.default.removeItem(at: root.appendingPathComponent("a.txt"))
    try await service.stage(paths: ["a.txt"], at: root)
    entry = try await change(root, "a.txt")
    checkEqual(entry?.staged, true, "discard staged deletion: deletion is staged")
    _ = try await service.discard(paths: ["a.txt"], at: root, includeStaged: true)
    checkEqual(try read(root, "a.txt"), "one", "discard staged deletion: file restored from HEAD")
    changes = try await service.snapshot(at: root).changes
    checkEqual(changes.count, 0, "discard staged deletion: clean afterwards")
}

// MARK: - main

@main
struct GitReviewHarness {
    static func main() async {
        do {
            try await testFastForward()
            try await testMergeCommit()
            try await testConflictAndResolve()
            try await testAbortMerge()
            try await testUnstage()
            try await testUnstageUnbornHead()
            try await testStagedDiff()
            try await testDiscard()
            try await testDiscardStaged()
            try await testPathSafety()
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
        print("ALL GIT REVIEW CHECKS PASSED")
    }
}
