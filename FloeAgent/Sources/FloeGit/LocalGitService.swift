import Foundation
import FloeCore
import SwiftGitX
import libgit2

/// Native Git operations for a security-scoped workspace. libgit2 is used
/// directly for authenticated network operations so credentials are supplied
/// through callbacks and never persisted in `.git/config` or a remote URL.
public actor LocalGitService {
    public static let shared = LocalGitService()
    /// Posted after every successful local mutation (init, stage, unstage,
    /// discard, commit, branch switch/create, merge, pull, abort, clone) with
    /// `GitRepositoryChange.rootKey` set to the URL the operation ran at.
    ///
    /// Source-control surfaces subscribe instead of polling, so a repository
    /// created or changed by an agent tool, a guest shell or another surface
    /// becomes visible immediately. The notification says "something in this
    /// tree changed"; it never claims which files, and readers still take a
    /// fresh snapshot.
    func postRepositoryDidChange(at root: URL) {
        NotificationCenter.default.post(
            name: .floeGitRepositoryDidChange,
            object: nil,
            userInfo: [GitRepositoryChange.rootKey: root.standardizedFileURL]
        )
    }

    public init() {}

    /// Walks up from `root` through its ancestors to the nearest directory
    /// that contains a `.git` entry — a directory for an ordinary repository,
    /// or a *file* for a linked worktree or submodule. Returns that repository
    /// root, or nil when no ancestor within the ownership boundary is a
    /// repository.
    ///
    /// Discovery is bounded by the *ownership boundary* — the app sandbox
    /// container on device (the user home on macOS) — instead of climbing
    /// through system directories above it. The boundary itself is still
    /// checked (a dotfiles home may be a repository); a workspace opened
    /// outside the container (for example a security-scoped cloud or external
    /// folder) still terminates at the filesystem root exactly as before.
    ///
    /// The existence probe is a direct POSIX `stat` rather than
    /// `FileManager.fileExists`. Build 211's FOUNDATION-namespace termination
    /// has `repositoryRoot(at:)` at its innermost app frame, and within that
    /// frame the probe call is the recorded location
    /// (`LocalGitService.swift:25` in the matching dSYM's line table), so the
    /// Foundation file-manager call was on the crashing path. The exact
    /// Foundation-level trigger is not proven, so this is an evidenced
    /// mitigation of the observed operation, not a claimed root-cause fix.
    /// There is deliberately **no arbitrary ancestor limit**: a repository or
    /// worktree stays discoverable at any depth below the boundary.
    public func repositoryRoot(at root: URL) -> URL? {
        repositoryRoot(at: root, ownershipBoundary: Self.ownershipBoundary)
    }

    /// The directory above which a workspace's repository is never searched:
    /// the app sandbox container on device, the user home on macOS.
    static var ownershipBoundary: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL
    }

    /// Testable core of `repositoryRoot(at:)` with an explicit boundary, so
    /// the stop condition is verified deterministically instead of depending
    /// on the real home directory.
    func repositoryRoot(at root: URL, ownershipBoundary: URL) -> URL? {
        // A non-file or pathless URL has no meaningful ancestors; probing it
        // previously fed an empty or malformed path into Foundation.
        guard root.isFileURL else { return nil }

        var candidate = root.standardizedFileURL
        // The boundary can be reached through a symlinked spelling (`/var`
        // vs `/private/var` on iOS), so both spellings are stop points.
        let boundary = ownershipBoundary.standardizedFileURL
        var boundaryPaths: Set<String> = [boundary.path]
        let resolvedBoundary = boundary.resolvingSymlinksInPath().path
        if !resolvedBoundary.isEmpty { boundaryPaths.insert(resolvedBoundary) }

        while true {
            let path = candidate.path
            guard !path.isEmpty, path.hasPrefix("/") else { return nil }

            if Self.hasGitEntry(in: path) { return candidate }

            // The boundary itself is checked first so a repository that *is*
            // the boundary (for example a dotfiles home) is still found; any
            // directory above it is outside every supported workspace.
            if boundaryPaths.contains(path) { return nil }

            // `deletingLastPathComponent` of the filesystem root returns
            // `/..` on Darwin (never the root itself), and comparing URLs
            // alone therefore never stops: a workspace outside the ownership
            // boundary — a security-scoped external/cloud folder, or a
            // developer-host temp directory in tests — walked `/..`,
            // `/../..`, … forever instead of reporting "no repository".
            // Compare standardized paths and stop when the parent no longer
            // shrinks, which covers the real root and the Darwin `..` form.
            let parentPath = candidate.deletingLastPathComponent().standardizedFileURL.path
            if parentPath.isEmpty || parentPath == path { return nil }
            candidate = URL(fileURLWithPath: parentPath, isDirectory: true)
        }
    }

    /// Single-syscall probe for the `.git` marker (a directory for an
    /// ordinary repository, a file for a linked worktree or submodule).
    /// `stat` follows symlinks, matching the previous `fileExists` semantics,
    /// and never throws.
    private static func hasGitEntry(in directory: String) -> Bool {
        var info = stat()
        return stat(directory + "/.git", &info) == 0
    }

    public func snapshot(at root: URL, commitLimit: Int = 30) throws -> GitRepositorySnapshot {
        guard let repositoryRoot = repositoryRoot(at: root) else {
            return GitRepositorySnapshot(isRepository: false)
        }
        let repository = try Repository.open(at: repositoryRoot)
        // SwiftGitX collections (branch/status/remote/log) borrow the raw
        // repository pointer without retaining the `Repository`; its deinit
        // frees that pointer and shuts the runtime down. Optimized builds
        // may end an object's lifetime at its last use rather than at scope
        // end, so the whole borrowed read sequence stays inside one
        // `withExtendedLifetime` — no borrowed collection can outlive the
        // owner that keeps the native pointer valid.
        return try withExtendedLifetime(repository) {
            let branch: String?
            if let currentBranch = try? repository.branch.current.name {
                branch = currentBranch
            } else {
                branch = try symbolicHeadBranchName(at: repositoryRoot)
            }
            let branches = (try? repository.branch.list(.local).map(\.name).sorted()) ?? []
            let changes = try repository.status().flatMap(Self.changes(from:))
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let commits: [GitCommitSummary]
            if repository.isEmpty || repository.isHEADUnborn {
                commits = []
            } else {
                commits = Array(try repository.log().prefix(min(max(commitLimit, 1), 100))).map {
                    GitCommitSummary(
                        oid: $0.id.hex,
                        shortOID: $0.id.abbreviated,
                        message: $0.summary,
                        author: $0.author.name,
                        date: $0.date
                    )
                }
            }
            return GitRepositorySnapshot(
                isRepository: true,
                branch: branch,
                detachedHEAD: repository.isHEADDetached,
                branches: branches,
                remoteURL: (try? remoteEndpoint(at: repositoryRoot))?.transportURL,
                changes: changes,
                recentCommits: commits,
                repositoryRoot: repositoryRoot,
                indexRevision: try indexRevision(at: repositoryRoot), headOID: try headRevision(at: repositoryRoot)
            )
        }
    }

    /// Initializes a local repository at `root`. Local init never requires a
    /// remote account: `authorName`/`authorEmail` are optional and are only
    /// written when both are provided and valid; commit-time configuration
    /// still applies a verified identity for every commit.
    ///
    /// Initialization is idempotent: when `root` already is a repository
    /// (a `.git` entry at the root itself, not an ancestor), the existing
    /// repository is opened and snapshotted unchanged — its HEAD, config and
    /// history are never re-pointed or overwritten from here.
    @discardableResult
    public func initialize(
        at root: URL,
        authorName: String? = nil,
        authorEmail: String? = nil,
        initialBranch: String = "main"
    ) throws -> GitRepositorySnapshot {
        // An invalid target must fail as an ordinary validation error, never
        // as a libgit2 trap: a non-file URL (or a pathless one) fed into the
        // repository walk/init is the Build-211 crash family.
        guard root.isFileURL, !root.standardizedFileURL.path.isEmpty else {
            throw FloeError.validationFailed("Git repository root must be a local file URL")
        }
        var rootInfo = stat()
        guard stat(root.path, &rootInfo) == 0,
              (rootInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw FloeError.validationFailed("Git repository root must be an existing directory")
        }
        if repositoryRoot(at: root) == root.standardizedFileURL {
            return try snapshot(at: root)
        }
        let branchName = try Self.validBranch(initialBranch)
        try withRuntime {
            var repository: OpaquePointer?
            try Self.check(
                git_repository_init(&repository, root.path, 0),
                operation: "initialize repository"
            )
            guard let repository else {
                throw FloeError.internalError("Git repository pointer is unavailable")
            }
            defer { git_repository_free(repository) }

            var config: OpaquePointer?
            try Self.check(git_repository_config(&config, repository), operation: "open repository config")
            guard let config else { throw FloeError.internalError("Git repository config is unavailable") }
            defer { git_config_free(config) }
            if let authorName, let authorEmail {
                let identity = try Self.validIdentity(name: authorName, email: authorEmail)
                try Self.check(git_config_set_string(config, "user.name", identity.name), operation: "set git author name")
                try Self.check(git_config_set_string(config, "user.email", identity.email), operation: "set git author email")
            }
            try Self.check(git_config_set_string(config, "init.defaultBranch", branchName), operation: "set default branch")
            try Self.check(
                git_repository_set_head(repository, "refs/heads/\(branchName)"),
                operation: "set initial branch"
            )
        }
        postRepositoryDidChange(at: root)
        return try snapshot(at: root)
    }

    public func stageAll(at root: URL) throws {
        try withRawRepository(at: root) { repository in
            var index: OpaquePointer?
            try Self.check(git_repository_index(&index, repository), operation: "open index")
            guard let index else { throw FloeError.internalError("Git index is unavailable") }
            defer { git_index_free(index) }
            var pathspec = git_strarray()
            try Self.check(
                git_index_add_all(index, &pathspec, UInt32(GIT_INDEX_ADD_DEFAULT.rawValue), nil, nil),
                operation: "stage changes"
            )
            try Self.check(git_index_update_all(index, &pathspec, nil, nil), operation: "stage deletions")
            try Self.check(git_index_write(index), operation: "write index")
        }
        postRepositoryDidChange(at: root)
    }

    public func stage(paths: [String], at root: URL) throws {
        let safe = try paths.map(Self.validRelativePath)
        guard !safe.isEmpty else { throw FloeError.validationFailed("At least one path is required") }
        try withRawRepository(at: root) { repository in
            var index: OpaquePointer?
            try Self.check(git_repository_index(&index, repository), operation: "open index")
            guard let index else { throw FloeError.internalError("Git index is unavailable") }
            defer { git_index_free(index) }
            for path in safe {
                let absolute = root.appendingPathComponent(path).standardizedFileURL
                let status = FileManager.default.fileExists(atPath: absolute.path)
                    ? git_index_add_bypath(index, path)
                    : git_index_remove_bypath(index, path)
                try Self.check(status, operation: "stage \(path)")
            }
            try Self.check(git_index_write(index), operation: "write index")
        }
        postRepositoryDidChange(at: root)
    }

    /// Removes paths from the index without touching the working tree
    /// (the ordinary `git restore --staged` / "unstage" action). A staged new
    /// file becomes untracked again; a staged modification returns to HEAD.
    public func unstage(paths: [String], at root: URL) throws {
        let safe = try paths.map(Self.validRelativePath)
        guard !safe.isEmpty else { throw FloeError.validationFailed("At least one path is required") }
        let repository = try Repository.open(at: root)
        if let head = try Self.headCommit(repository) {
            try repository.reset(from: head, paths: safe)
            postRepositoryDidChange(at: root)
            return
        }
        // Unborn HEAD: the index has no baseline, so drop the entries.
        try withRawRepository(at: root) { raw in
            var index: OpaquePointer?
            try Self.check(git_repository_index(&index, raw), operation: "open index")
            guard let index else { throw FloeError.internalError("Git index is unavailable") }
            defer { git_index_free(index) }
            for path in safe {
                try Self.check(git_index_remove_bypath(index, path), operation: "unstage \(path)")
            }
            try Self.check(git_index_write(index), operation: "write index")
        }
        postRepositoryDidChange(at: root)
    }

    /// Discards changes for `paths`. The working tree is always restored from
    /// the index (never from an unverified remote) and untracked files are
    /// removed; with `includeStaged` the index entry is first reset to HEAD so
    /// a staged addition/modification/deletion is discarded as well. A private
    /// recovery copy of both the working tree and (when staged) the index bytes
    /// is written first under `.git/floe-recovery/` so the operation is
    /// reversible after the fact.
    public func discard(paths: [String], at root: URL, includeStaged: Bool = false) throws -> GitDiscardOutcome {
        let safe = try paths.map(Self.validRelativePath)
        guard !safe.isEmpty else { throw FloeError.validationFailed("At least one path is required") }

        // Capture every byte this call is about to remove, before any reset.
        let stagedTargets: [String]
        if includeStaged {
            let repository = try Repository.open(at: root)
            let staged = try Self.stagedPaths(in: repository)
            stagedTargets = safe.filter { staged.contains($0) }
        } else {
            stagedTargets = []
        }
        guard !(try snapshot(at: root).changes.contains { $0.kind == .conflicted && safe.contains($0.path) }) else {
            throw FloeError.validationFailed(FloeL10n.isChinese ? "请先解决冲突或中止合并。" : "Resolve the conflict or abort the merge first.")
        }
        let recovery = try captureRecovery(paths: safe, at: root, includeIndex: includeStaged)
        if !stagedTargets.isEmpty { try unstage(paths: stagedTargets, at: root) }

        // Re-open: the reset above changed the index on disk.
        let repository = try Repository.open(at: root)
        var untracked = Set<String>()
        for entry in try repository.status() {
            let delta = entry.workingTree ?? entry.index
            guard let delta else { continue }
            if entry.status.contains(where: { if case .workingTreeNew = $0 { true } else { false } }) {
                untracked.insert(delta.newFile.path)
            }
        }
        let tracked = safe.filter { !untracked.contains($0) }
        if !tracked.isEmpty {
            try repository.restore(.workingTree, paths: tracked)
        }
        let rootPrefix = root.standardizedFileURL.path + "/"
        for path in safe where untracked.contains(path) {
            let url = root.appendingPathComponent(path).standardizedFileURL
            guard url.path.hasPrefix(rootPrefix) else {
                throw FloeError.validationFailed("Git path must stay inside the workspace")
            }
            try FileManager.default.removeItem(at: url)
        }
        postRepositoryDidChange(at: root)
        _ = try finishRecovery(recovery, at: root)
        return GitDiscardOutcome(discardedPaths: safe, recoveryPath: try recoveryBase(root).appendingPathComponent(recovery.id).path, recoveryID: recovery.id)
    }

    @discardableResult
    public func commit(
        at root: URL,
        message: String,
        authorName: String,
        authorEmail: String
    ) throws -> GitCommitSummary {
        let value = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 8_192 else {
            throw FloeError.validationFailed("Commit message must contain 1 to 8192 bytes")
        }
        let repository = try Repository.open(at: root)
        try configureIfMissing(repository, authorName: authorName, authorEmail: authorEmail)
        let commit = try repository.commit(message: value)
        postRepositoryDidChange(at: root)
        return GitCommitSummary(
            oid: commit.id.hex,
            shortOID: commit.id.abbreviated,
            message: commit.summary,
            author: commit.author.name,
            date: commit.date
        )
    }

    public func diff(at root: URL, path: String? = nil, maxBytes: Int = 512 * 1024) throws -> String {
        let repository = try Repository.open(at: root)
        return try Self.format(diff: repository.diff(to: [.workingTree, .index]), path: path, maxBytes: maxBytes)
    }

    /// Staged-vs-HEAD diff (`git diff --cached`).
    public func diffStaged(at root: URL, path: String? = nil, maxBytes: Int = 512 * 1024) throws -> String {
        let repository = try Repository.open(at: root)
        return try Self.format(diff: repository.diff(to: .index), path: path, maxBytes: maxBytes)
    }

    private static func format(diff: Diff, path: String?, maxBytes: Int) throws -> String {
        let requestedPath = try path.map(Self.validRelativePath)
        var result = ""
        for patch in diff.patches {
            let newPath = patch.delta.newFile.path
            let oldPath = patch.delta.oldFile.path
            if let requestedPath, requestedPath != newPath, requestedPath != oldPath { continue }
            result += "diff --git a/\(oldPath) b/\(newPath)\n"
            result += "--- a/\(oldPath)\n+++ b/\(newPath)\n"
            for hunk in patch.hunks {
                result += hunk.header
                if !result.hasSuffix("\n") { result += "\n" }
                for line in hunk.lines {
                    result += line.type.rawValue + line.content
                    if !result.hasSuffix("\n") { result += "\n" }
                    if result.utf8.count >= maxBytes {
                        return String(decoding: Data(result.utf8).prefix(maxBytes), as: UTF8.self)
                            + "\n[diff truncated]\n"
                    }
                }
            }
        }
        return result
    }

    public func switchBranch(at root: URL, name: String) throws {
        let repository = try Repository.open(at: root)
        guard try repository.status().isEmpty else {
            throw FloeError.validationFailed("Commit or discard workspace changes before switching branches")
        }
        let branchName = try Self.validBranch(name)
        let branch = try repository.branch.get(named: branchName, type: .local)
        try repository.switch(to: branch)
        postRepositoryDidChange(at: root)
    }

    public func createBranch(at root: URL, name: String, switchToBranch: Bool = true) throws {
        let repository = try Repository.open(at: root)
        let head: Commit?
        if repository.isEmpty {
            head = nil
        } else {
            let iterator = try repository.log().makeIterator()
            head = iterator.next()
        }
        guard let head else {
            throw FloeError.validationFailed("Create the first commit before creating a branch")
        }
        let branch = try repository.branch.create(named: Self.validBranch(name), target: head)
        if switchToBranch { try repository.switch(to: branch) }
        postRepositoryDidChange(at: root)
    }

    public func clone(from remoteURL: URL, to destination: URL, token: String?) async throws {
        let endpoint = try GitRemoteEndpoint(remoteURL.absoluteString)
        _ = try await clone(to: destination, authentication: Self.legacyAuthentication(endpoint: endpoint, token: token))
    }

    public func fetch(at root: URL, token: String?) async throws {
        let endpoint = try remoteEndpoint(at: root)
        try await fetch(at: root, authentication: Self.legacyAuthentication(endpoint: endpoint, token: token))
    }

    public func push(at root: URL, token: String?) async throws {
        let endpoint = try remoteEndpoint(at: root, pushing: true)
        try await push(at: root, authentication: Self.legacyAuthentication(endpoint: endpoint, token: token))
    }

    /// The caller resolves host-bound material through the existing App
    /// credential/host store. A remote URL edit between resolution and use
    /// fails before any credential is submitted.
    public func remoteEndpoint(at root: URL, name: String = "origin", pushing: Bool = false) throws -> GitRemoteEndpoint {
        try GitNativeRemoteDriver.runtime {
            try GitNativeRemoteDriver.validRemoteName(name)
            return try GitNativeRemoteDriver.repository(root) { try GitNativeRemoteDriver.endpoint($0, name: name, pushing: pushing) }
        }
    }

    public func remotes(at root: URL) throws -> [GitRemoteDescriptor] {
        try GitNativeRemoteDriver.runtime {
            try GitNativeRemoteDriver.repository(root) { repository in
                var names = git_strarray(); defer { git_strarray_dispose(&names) }
                try GitNativeRemoteDriver.check(git_remote_list(&names, repository))
                guard let strings = names.strings else { return [] }
                return try (0..<names.count).compactMap { index in
                    guard let string = strings[index] else { return nil }
                    let name = String(cString: string)
                    return try GitRemoteDescriptor(name: name,
                        fetch: GitNativeRemoteDriver.endpoint(repository, name: name, pushing: false),
                        push: GitNativeRemoteDriver.endpoint(repository, name: name, pushing: true))
                }
            }
        }
    }

    public func setRemote(at root: URL, name: String, fetch: GitRemoteEndpoint, push: GitRemoteEndpoint? = nil) throws {
        try GitNativeRemoteDriver.runtime {
            try GitNativeRemoteDriver.validRemoteName(name)
            try GitNativeRemoteDriver.repository(root) { repository in
                var existing: OpaquePointer?
                let lookup = git_remote_lookup(&existing, repository, name)
                defer { git_remote_free(existing) }
                if lookup == GIT_ENOTFOUND.rawValue {
                    try GitNativeRemoteDriver.check(git_remote_create(&existing, repository, name, fetch.transportURL))
                } else { try GitNativeRemoteDriver.check(lookup); try GitNativeRemoteDriver.check(git_remote_set_url(repository, name, fetch.transportURL)) }
                let pushResult = git_remote_set_pushurl(repository, name, push?.transportURL)
                if !(push == nil && pushResult == GIT_ENOTFOUND.rawValue) {
                    try GitNativeRemoteDriver.check(pushResult)
                }
            }
        }
        postRepositoryDidChange(at: root)
    }

    @discardableResult
    public func clone(to destination: URL, authentication: GitRemoteAuthentication,
                      progress: (@Sendable (GitRemoteProgress) -> Void)? = nil) async throws -> GitCloneReceipt {
        let context = GitNativeRemoteContext(authentication: authentication, progress: progress)
        let receipt = try await withTaskCancellationHandler {
            try GitNativeRemoteDriver.clone(to: destination, context: context)
        } onCancel: { context.cancel() }
        postRepositoryDidChange(at: destination); return receipt
    }

    public func fetch(at root: URL, remoteName: String = "origin", authentication: GitRemoteAuthentication,
                      progress: (@Sendable (GitRemoteProgress) -> Void)? = nil) async throws {
        let context = GitNativeRemoteContext(authentication: authentication, progress: progress)
        try await withTaskCancellationHandler {
            try GitNativeRemoteDriver.fetch(root, name: remoteName, context: context)
        } onCancel: { context.cancel() }
        postRepositoryDidChange(at: root)
    }

    public func push(at root: URL, remoteName: String = "origin", destinationBranch: String? = nil,
                     authentication: GitRemoteAuthentication,
                     progress: (@Sendable (GitRemoteProgress) -> Void)? = nil) async throws {
        let context = GitNativeRemoteContext(authentication: authentication, progress: progress)
        try await withTaskCancellationHandler {
            try GitNativeRemoteDriver.push(root, name: remoteName, destinationBranch: destinationBranch, context: context)
        } onCancel: { context.cancel() }
        postRepositoryDidChange(at: root)
    }

    /// Compatibility for existing callers: the saved GitHub token is never
    /// offered to an unrelated generic HTTPS/SSH host. New callers choose an
    /// approved credential for their actual endpoint instead.
    private static func legacyAuthentication(endpoint: GitRemoteEndpoint, token: String?) throws -> GitRemoteAuthentication {
        if endpoint.transport == .https, endpoint.host == "github.com", endpoint.port == 443, let token, !token.isEmpty {
            return try .https(for: endpoint, username: "x-access-token", password: Data(token.utf8))
        }
        return .anonymous(for: endpoint)
    }

    /// Fetches then performs a fast-forward-only update. Dirty workspaces and
    /// diverged histories are left untouched and surfaced to the caller.
    public func pullFastForward(at root: URL, token: String?) async throws {
        let before = try Repository.open(at: root)
        guard try before.status().isEmpty else {
            throw FloeError.validationFailed("Commit workspace changes before pulling")
        }
        try await fetch(at: root, token: token)
        let repository = try Repository.open(at: root)
        guard try repository.status().isEmpty else {
            throw FloeError.validationFailed("Workspace changed during fetch; commit or restore changes before pulling")
        }
        let current = try repository.branch.current
        guard let upstream = current.upstream as? Branch,
              let upstreamCommit = upstream.target as? Commit,
              let localCommit = current.target as? Commit else {
            throw FloeError.validationFailed("Current branch has no upstream")
        }
        if upstreamCommit.id == localCommit.id { return }
        let relation = try Self.graphRelation(at: root, local: localCommit.id.hex, upstream: upstreamCommit.id.hex)
        guard relation == .upstreamDescendsFromLocal else {
            throw FloeError.validationFailed("Pull requires a merge; Floe only performs safe fast-forward pulls")
        }
        try repository.reset(to: upstreamCommit, mode: .hard)
        postRepositoryDidChange(at: root)
    }

    // MARK: - Merge and conflict resolution

    /// Merges `refName` (a full ref such as `refs/heads/feature`) into the
    /// current branch. Fast-forwards when possible; otherwise performs a real
    /// merge and leaves conflicted paths for explicit resolution. Force-push
    /// and rebase are deliberately not implemented.
    @discardableResult
    public func mergeRef(at root: URL, refName: String, authorName: String, authorEmail: String) throws -> GitMergeOutcome {
        let outcome = try withRawRepository(at: root) { repository in
            var reference: OpaquePointer?
            try Self.check(git_reference_lookup(&reference, repository, refName), operation: "resolve merge target")
            guard let reference else { throw FloeError.validationFailed("Merge target was not found") }
            defer { git_reference_free(reference) }
            var annotated: OpaquePointer?
            try Self.check(git_annotated_commit_from_ref(&annotated, repository, reference), operation: "prepare merge")
            guard let annotatedCommit = annotated else { throw FloeError.internalError("Git merge target is unavailable") }
            defer { git_annotated_commit_free(annotatedCommit) }
            var analysis = GIT_MERGE_ANALYSIS_NONE
            var preference = GIT_MERGE_PREFERENCE_NONE
            try Self.check(
                git_merge_analysis(&analysis, &preference, repository, &annotated, 1),
                operation: "analyze merge"
            )
            if analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 {
                return GitMergeOutcome(result: .upToDate, message: FloeL10n.l("git.local_git_service.already_up_to_date"))
            }
            if analysis.rawValue & GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue != 0,
               let targetOID = git_annotated_commit_id(annotatedCommit) {
                // Fast-forward the *current* branch (`HEAD`), not the ref that
                // was passed in. Checking the target tree out first keeps HEAD
                // untouched when the working tree refuses the update.
                var targetObject: OpaquePointer?
                try Self.check(
                    git_object_lookup(&targetObject, repository, targetOID, GIT_OBJECT_COMMIT),
                    operation: "lookup merge target"
                )
                guard let targetObject else { throw FloeError.internalError("Git merge target is unavailable") }
                defer { git_object_free(targetObject) }
                var checkoutOptions = git_checkout_options()
                try Self.check(
                    git_checkout_options_init(&checkoutOptions, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)),
                    operation: "initialize fast-forward checkout"
                )
                checkoutOptions.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
                try Self.check(
                    git_checkout_tree(repository, targetObject, &checkoutOptions),
                    operation: "update working tree"
                )
                var headReference: OpaquePointer?
                try Self.check(git_repository_head(&headReference, repository), operation: "resolve HEAD")
                guard let headReference else { throw FloeError.internalError("Git HEAD is unavailable") }
                defer { git_reference_free(headReference) }
                var updated: OpaquePointer?
                try Self.check(
                    git_reference_set_target(&updated, headReference, targetOID, "floe: fast-forward merge"),
                    operation: "fast-forward"
                )
                git_reference_free(updated)
                return GitMergeOutcome(result: .fastForward, message: FloeL10n.l("git.local_git_service.fast_forward_merged"))
            }
            try configureIfMissing(Repository.open(at: root), authorName: authorName, authorEmail: authorEmail)
            var mergeOptions = git_merge_options()
            try Self.check(
                git_merge_options_init(&mergeOptions, UInt32(GIT_MERGE_OPTIONS_VERSION)),
                operation: "initialize merge"
            )
            var checkoutOptions = git_checkout_options()
            try Self.check(
                git_checkout_options_init(&checkoutOptions, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)),
                operation: "initialize merge checkout"
            )
            checkoutOptions.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
            try Self.check(
                git_merge(repository, &annotated, 1, &mergeOptions, &checkoutOptions),
                operation: "merge"
            )
            let conflicts = try Self.conflictedPaths(raw: repository)
            if !conflicts.isEmpty {
                return GitMergeOutcome(
                    result: .conflicts,
                    message: FloeL10n.l("git.local_git_service.the_merge_has_conflicts_resolve_each"),
                    conflictedPaths: conflicts
                )
            }
            try Self.createMergeCommit(raw: repository, message: (try? Self.mergeMessage(at: root)) ?? "Merge")
            return GitMergeOutcome(result: .merged, message: FloeL10n.l("git.local_git_service.merge_complete"))
        }
        postRepositoryDidChange(at: root)
        return outcome
    }

    /// Fetches and merges the current branch's configured upstream. This is
    /// the ordinary pull with a merge fallback; it never rewrites local
    /// commits (no rebase, no force).
    @discardableResult
    public func pullMerge(at root: URL, token: String?, authorName: String, authorEmail: String) async throws -> GitMergeOutcome {
        try await fetch(at: root, token: token)
        let repository = try Repository.open(at: root)
        let branch = try repository.branch.current
        guard let upstreamName = branch.upstream?.name else {
            throw FloeError.validationFailed("Current branch has no upstream")
        }
        // `Branch.name` for a remote-tracking branch already carries the
        // remote prefix ("origin/main"); never double it.
        let refName = upstreamName.hasPrefix("refs/") ? upstreamName : "refs/remotes/\(upstreamName)"
        return try mergeRef(at: root, refName: refName, authorName: authorName, authorEmail: authorEmail)
    }

    public func isMerging(at root: URL) throws -> Bool {
        try withRawRepository(at: root) { repository in
            git_repository_state(repository) == Int32(GIT_REPOSITORY_STATE_MERGE.rawValue)
        }
    }

    /// Stages one resolved conflict. When no unmerged entries remain, the
    /// pending merge commit is created from the recorded MERGE_MSG.
    @discardableResult
    public func resolveConflict(at root: URL, path: String, content: String?, authorName: String, authorEmail: String) throws -> GitMergeOutcome {
        let safe = try Self.validRelativePath(path)
        try configureIfMissing(Repository.open(at: root), authorName: authorName, authorEmail: authorEmail)
        let outcome = try withRawRepository(at: root) { repository in
            let url = root.appendingPathComponent(safe).standardizedFileURL
            guard url.path.hasPrefix(root.standardizedFileURL.path + "/") else {
                throw FloeError.validationFailed("Git path must stay inside the workspace")
            }
            var index: OpaquePointer?
            try Self.check(git_repository_index(&index, repository), operation: "open index")
            guard let index else { throw FloeError.internalError("Git index is unavailable") }
            defer { git_index_free(index) }
            if let content {
                try Data(content.utf8).write(to: url, options: .atomic)
                try Self.check(git_index_add_bypath(index, safe), operation: "stage resolved path")
            } else {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                try Self.check(git_index_conflict_remove(index, safe), operation: "resolve deleted conflict")
                let removed = git_index_remove_bypath(index, safe)
                if removed != GIT_ENOTFOUND.rawValue { try Self.check(removed, operation: "stage resolved deletion") }
            }
            try Self.check(git_index_write(index), operation: "write index")
            let remaining = try Self.conflictedPaths(raw: repository)
            guard remaining.isEmpty else {
                return GitMergeOutcome(
                    result: .conflicts,
                    message: FloeL10n.l("git.local_git_service.unresolved_conflicts_remain"),
                    conflictedPaths: remaining
                )
            }
            try Self.createMergeCommit(
                raw: repository,
                message: (try? Self.mergeMessage(at: root)) ?? "Merge"
            )
            return GitMergeOutcome(result: .merged, message: FloeL10n.l("git.local_git_service.conflicts_resolved_merge_complete"))
        }
        postRepositoryDidChange(at: root)
        return outcome
    }

    /// Returns the repository to its pre-merge state. Local commits are kept
    /// (hard reset to HEAD, never to a remote).
    public func abortMerge(at root: URL) throws {
        let before = try snapshot(at: root)
        guard try isMerging(at: root) else { throw FloeError.validationFailed("No merge is in progress") }
        let paths = Array(Set(before.changes.map(\.path))).sorted()
        var recovery: GitRecoveryRecord?
        try withRawRepository(at: root) { repository in
            var oid = git_oid()
            try Self.check(git_reference_name_to_id(&oid, repository, "HEAD"), operation: "resolve HEAD")
            var object: OpaquePointer?
            try Self.check(git_object_lookup(&object, repository, &oid, GIT_OBJECT_COMMIT), operation: "lookup HEAD commit")
            guard let object else { throw FloeError.internalError("Git HEAD commit is unavailable") }
            defer { git_object_free(object) }
            let saved = try captureRecovery(paths: paths, at: root, includeIndex: true, kind: "abortMerge", allowConflicts: true)
            recovery = saved
            if let rawDirectory = git_repository_path(repository) {
                let directory = URL(fileURLWithPath: String(cString: rawDirectory), isDirectory: true)
                let destination = try recoveryBase(root).appendingPathComponent(saved.id)
                for name in ["index", "MERGE_HEAD", "MERGE_MSG", "ORIG_HEAD"] {
                    let source = directory.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: source.path) {
                        try FileManager.default.copyItem(at: source, to: destination.appendingPathComponent("git-" + name + ".raw"))
                    }
                }
            }
            try Self.check(git_reset(repository, object, GIT_RESET_HARD, nil), operation: "abort merge")
            try Self.check(git_repository_state_cleanup(repository), operation: "clean merge state")
        }
        if let recovery { _ = try finishRecovery(recovery, at: root) }
        postRepositoryDidChange(at: root)
    }

    private static func createMergeCommit(raw repository: OpaquePointer, message: String) throws {
        var mergeHeadOID = git_oid()
        try check(git_reference_name_to_id(&mergeHeadOID, repository, "MERGE_HEAD"), operation: "read MERGE_HEAD")
        var headReference: OpaquePointer?
        try check(git_repository_head(&headReference, repository), operation: "resolve HEAD")
        guard let headReference, let headOID = git_reference_target(headReference) else {
            git_reference_free(headReference)
            throw FloeError.validationFailed("Git HEAD is not a commit")
        }
        defer { git_reference_free(headReference) }
        var index: OpaquePointer?
        try check(git_repository_index(&index, repository), operation: "open merged index")
        guard let index else { throw FloeError.internalError("Git index is unavailable") }
        defer { git_index_free(index) }
        try check(git_index_write(index), operation: "write merged index")
        var treeOID = git_oid()
        try check(git_index_write_tree(&treeOID, index), operation: "write merged tree")
        var tree: OpaquePointer?
        try check(git_tree_lookup(&tree, repository, &treeOID), operation: "lookup merged tree")
        guard let tree else { throw FloeError.internalError("Git merged tree is unavailable") }
        defer { git_tree_free(tree) }
        var headObject: OpaquePointer?
        try check(git_object_lookup(&headObject, repository, headOID, GIT_OBJECT_COMMIT), operation: "lookup HEAD commit")
        guard let headObject else { throw FloeError.internalError("Git HEAD commit is unavailable") }
        defer { git_object_free(headObject) }
        var mergeHeadObject: OpaquePointer?
        try check(git_object_lookup(&mergeHeadObject, repository, &mergeHeadOID, GIT_OBJECT_COMMIT), operation: "lookup merge commit")
        guard let mergeHeadObject else { throw FloeError.internalError("Git merge commit is unavailable") }
        defer { git_object_free(mergeHeadObject) }
        var signature: UnsafeMutablePointer<git_signature>?
        try check(git_signature_default(&signature, repository), operation: "read git identity")
        guard let signature else { throw FloeError.invalidConfiguration("Git author identity is not configured") }
        defer { git_signature_free(signature) }
        var parents: [OpaquePointer?] = [headObject, mergeHeadObject]
        var commitOID = git_oid()
        try parents.withUnsafeMutableBufferPointer { buffer in
            try check(
                git_commit_create(
                    &commitOID, repository, "HEAD", signature, signature, nil,
                    message, tree, 2, buffer.baseAddress
                ),
                operation: "create merge commit"
            )
        }
        try check(git_repository_state_cleanup(repository), operation: "clean merge state")
    }

    private static func conflictedPaths(raw repository: OpaquePointer) throws -> [String] {
        var index: OpaquePointer?
        try check(git_repository_index(&index, repository), operation: "open index")
        guard let index else { throw FloeError.internalError("Git index is unavailable") }
        defer { git_index_free(index) }
        var iterator: OpaquePointer?
        try check(git_index_conflict_iterator_new(&iterator, index), operation: "open conflict iterator")
        guard let iterator else { throw FloeError.internalError("Git conflict iterator is unavailable") }
        defer { git_index_conflict_iterator_free(iterator) }
        var paths: [String] = []
        while true {
            var ancestor: UnsafePointer<git_index_entry>?
            var ours: UnsafePointer<git_index_entry>?
            var theirs: UnsafePointer<git_index_entry>?
            let status = git_index_conflict_next(&ancestor, &ours, &theirs, iterator)
            if status == GIT_ITEROVER.rawValue { break }
            try check(status, operation: "read conflict entry")
            guard let entry = theirs ?? ours ?? ancestor else { continue }
            // `git_index_entry.path` is a `const char *` in the pinned
            // libgit2; read the pointed-to C string, never the pointer bytes.
            guard let rawPath = entry.pointee.path else { continue }
            let path = String(cString: rawPath)
            if !paths.contains(path) { paths.append(path) }
        }
        return paths
    }

    private static func mergeMessage(at root: URL) throws -> String {
        let url = root.appendingPathComponent(".git/MERGE_MSG")
        let data = try Data(contentsOf: url)
        let value = String(decoding: data.prefix(8_192), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Merge" : value
    }

    private static func headCommit(_ repository: Repository) throws -> Commit? {
        guard !repository.isEmpty, !repository.isHEADUnborn else { return nil }
        return Array(try repository.log().prefix(1)).first
    }

    /// Paths that currently have an index-side (staged) delta.
    private static func stagedPaths(in repository: Repository) throws -> Set<String> {
        var result = Set<String>()
        for entry in try repository.status() where entry.index != nil {
            guard let delta = entry.index ?? entry.workingTree else { continue }
            if !delta.newFile.path.isEmpty { result.insert(delta.newFile.path) }
            if !delta.oldFile.path.isEmpty { result.insert(delta.oldFile.path) }
        }
        return result
    }

    /// Unique, inspectable folder for one discard operation.
    private static func recoveryFolder(at root: URL) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let folderName = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return root.appendingPathComponent(
            ".git/floe-recovery/\(folderName)-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
    }

    /// Preserves the working-tree bytes that `discard` is about to remove. Only
    /// regular files inside the workspace are copied; the copy lives under
    /// `.git/floe-recovery/<timestamp>-<uuid>/` so it is inspectable and can be
    /// restored manually. Returns false when nothing existed to copy.
    func writeRecoveryCopy(paths: [String], at root: URL, folder: URL) throws -> Bool {
        let rootPrefix = root.standardizedFileURL.path + "/"
        var copied = false
        for path in paths {
            let source = root.appendingPathComponent(path).standardizedFileURL
            guard source.path.hasPrefix(rootPrefix),
                  FileManager.default.fileExists(atPath: source.path) else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let destination = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
            copied = true
        }
        return copied
    }

    /// Preserves the *staged* (index) bytes for paths whose index entry is
    /// about to be reset. They are stored beside the working-tree copy as
    /// `<path>.staged` so a partially staged file never loses the version the
    /// user had staged. Returns false when no index blob was found.
    func writeIndexRecovery(paths: [String], at root: URL, folder: URL) throws -> Bool {
        try withRawRepository(at: root) { raw in
            var index: OpaquePointer?
            try Self.check(git_repository_index(&index, raw), operation: "open index for recovery")
            guard let index else { throw FloeError.internalError("Git index is unavailable") }
            defer { git_index_free(index) }
            var copied = false
            for path in paths {
                guard let entry = git_index_get_bypath(index, path, 0) else { continue }
                var oid = entry.pointee.id
                var blob: OpaquePointer?
                guard git_blob_lookup(&blob, raw, &oid) >= 0, let blob else { continue }
                defer { git_blob_free(blob) }
                let size = Int(git_blob_rawsize(blob))
                let data: Data
                if size == 0 { data = Data() }
                else if let content = git_blob_rawcontent(blob) {
                    data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: content), count: size, deallocator: .none)
                } else { throw FloeError.storageCorrupted("Staged Git blob is unavailable") }
                let destination = folder.appendingPathComponent(path + ".staged")
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
                copied = true
            }
            return copied
        }
    }

    /// Applies `authorName`/`authorEmail` only when the repository does not
    /// already carry an identity. A user-supplied or clone-provided
    /// `user.name`/`user.email` always wins; the supplied identity is a
    /// fallback for repositories that have none (the common case right after
    /// a local init without an author).
    private func configureIfMissing(_ repository: Repository, authorName: String, authorEmail: String) throws {
        let existingName = (try? repository.config.string(forKey: "user.name")) ?? nil
        let existingEmail = (try? repository.config.string(forKey: "user.email")) ?? nil
        let hasName = existingName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasEmail = existingEmail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if hasName && hasEmail { return }
        try configure(repository, authorName: authorName, authorEmail: authorEmail)
    }

    private func configure(_ repository: Repository, authorName: String, authorEmail: String) throws {
        let identity = try Self.validIdentity(name: authorName, email: authorEmail)
        try repository.config.set("user.name", to: identity.name)
        try repository.config.set("user.email", to: identity.email)
    }

    private static func validIdentity(name authorName: String, email authorEmail: String) throws -> (name: String, email: String) {
        let name = authorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = authorEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200,
              email.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil else {
            throw FloeError.validationFailed("Git author name or email is invalid")
        }
        return (name, email)
    }

    private func withRawRepository<T>(at root: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        try withRuntime {
            var repository: OpaquePointer?
            try Self.check(git_repository_open(&repository, root.path), operation: "open repository")
            guard let repository else { throw FloeError.internalError("Git repository pointer is unavailable") }
            defer { git_repository_free(repository) }
            return try body(repository)
        }
    }

    /// libgit2 cannot resolve `repository.branch.current` until the first
    /// commit exists. Read symbolic HEAD directly so a freshly initialized
    /// workspace still reports its intended branch to the UI and tools.
    private func symbolicHeadBranchName(at root: URL) throws -> String? {
        try withRawRepository(at: root) { repository in
            var reference: OpaquePointer?
            let result = git_reference_lookup(&reference, repository, "HEAD")
            if result == GIT_ENOTFOUND.rawValue { return nil }
            try Self.check(result, operation: "resolve symbolic HEAD")
            guard let reference else { return nil }
            defer { git_reference_free(reference) }
            guard let rawTarget = git_reference_symbolic_target(reference) else { return nil }
            let target = String(cString: rawTarget)
            let prefix = "refs/heads/"
            return target.hasPrefix(prefix) ? String(target.dropFirst(prefix.count)) : nil
        }
    }

    private func withRuntime<T>(_ body: () throws -> T) throws -> T {
        guard git_libgit2_init() >= 0 else { throw FloeError.internalError("libgit2 initialization failed") }
        defer { _ = git_libgit2_shutdown() }
        return try body()
    }

    private enum GraphRelation { case upstreamDescendsFromLocal, other }

    private static func graphRelation(at root: URL, local: String, upstream: String) throws -> GraphRelation {
        var repository: OpaquePointer?
        try check(git_repository_open(&repository, root.path), operation: "open repository graph")
        guard let repository else { throw FloeError.internalError("Git repository pointer is unavailable") }
        defer { git_repository_free(repository) }
        var localOID = git_oid()
        var upstreamOID = git_oid()
        try check(git_oid_fromstr(&localOID, local), operation: "parse local commit")
        try check(git_oid_fromstr(&upstreamOID, upstream), operation: "parse upstream commit")
        let descends = git_graph_descendant_of(repository, &upstreamOID, &localOID)
        if descends == 1 { return .upstreamDescendsFromLocal }
        try check(descends, operation: "compare branch history")
        return .other
    }

    private static func changes(from entry: SwiftGitX.StatusEntry) -> [GitFileChange] {
        if entry.status.contains(where: { if case .conflicted = $0 { true } else { false } }) {
            guard let delta = entry.workingTree ?? entry.index else { return [] }
            return [.init(path: delta.newFile.path.isEmpty ? delta.oldFile.path : delta.newFile.path, kind: .conflicted, staged: false)]
        }
        return [false, true].compactMap { staged in
            guard let delta = staged ? entry.index : entry.workingTree else { return nil }
            let kind: GitChangeKind
            if staged {
                if entry.status.contains(where: { if case .indexNew = $0 { true } else { false } }) { kind = .added }
                else if entry.status.contains(where: { if case .indexDeleted = $0 { true } else { false } }) { kind = .deleted }
                else if entry.status.contains(where: { if case .indexRenamed = $0 { true } else { false } }) { kind = .renamed }
                else if entry.status.contains(where: { if case .indexTypeChange = $0 { true } else { false } }) { kind = .typeChanged }
                else { kind = .modified }
            } else {
                if entry.status.contains(where: { if case .workingTreeNew = $0 { true } else { false } }) { kind = .untracked }
                else if entry.status.contains(where: { if case .workingTreeDeleted = $0 { true } else { false } }) { kind = .deleted }
                else if entry.status.contains(where: { if case .workingTreeRenamed = $0 { true } else { false } }) { kind = .renamed }
                else if entry.status.contains(where: { if case .workingTreeTypeChange = $0 { true } else { false } }) { kind = .typeChanged }
                else { kind = .modified }
            }
            return .init(path: kind == .deleted ? delta.oldFile.path : delta.newFile.path,
                         oldPath: kind == .renamed ? delta.oldFile.path : nil, kind: kind, staged: staged)
        }
    }

    private static func validRelativePath(_ path: String) throws -> String {
        let value = path.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\0"), !value.hasPrefix("/"), !value.split(separator: "/").contains(".."),
              !value.hasPrefix(".git/") && value != ".git" else {
            throw FloeError.validationFailed("Git path must stay inside the workspace")
        }
        return value
    }

    private static func validBranch(_ branch: String) throws -> String {
        let value = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^(?![.-])(?!.*\.\.)(?!.*//)[A-Za-z0-9._/-]{1,200}(?<![./])$"#, options: .regularExpression) != nil,
              !value.contains("@{") else {
            throw FloeError.validationFailed("Git branch name is invalid")
        }
        return value
    }

    private static func check(_ code: Int32, operation: String) throws {
        guard code >= 0 else {
            let raw: String
            if let message = git_error_last()?.pointee.message {
                raw = String(cString: UnsafePointer(message))
            } else {
                raw = "unknown libgit2 error"
            }
            throw FloeError.syncUnavailable("Git \(operation) failed: \(SecretRedactor.redact(raw))")
        }
    }

}
