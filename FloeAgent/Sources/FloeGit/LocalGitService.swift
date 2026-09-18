import Foundation
import FloeCore
import SwiftGitX
import libgit2

/// Native Git operations for a security-scoped workspace. libgit2 is used
/// directly for authenticated network operations so credentials are supplied
/// through callbacks and never persisted in `.git/config` or a remote URL.
public actor LocalGitService {
    public init() {}

    public func snapshot(at root: URL, commitLimit: Int = 30) throws -> GitRepositorySnapshot {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else {
            return GitRepositorySnapshot(isRepository: false)
        }
        let repository = try Repository.open(at: root)
        let branch: String?
        if let currentBranch = try? repository.branch.current.name {
            branch = currentBranch
        } else {
            branch = try symbolicHeadBranchName(at: root)
        }
        let branches = (try? repository.branch.list(.local).map(\.name).sorted()) ?? []
        let changes = try repository.status().compactMap(Self.change(from:))
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
            remoteURL: repository.remote["origin"]?.url.absoluteString,
            changes: changes,
            recentCommits: commits
        )
    }

    @discardableResult
    public func initialize(
        at root: URL,
        authorName: String,
        authorEmail: String,
        initialBranch: String = "main"
    ) throws -> GitRepositorySnapshot {
        let repository = try Repository(at: root)
        try configure(repository, authorName: authorName, authorEmail: authorEmail)
        let branchName = try Self.validBranch(initialBranch)
        try repository.config.set("init.defaultBranch", to: branchName)
        // `init.defaultBranch` only influences future initializations. Point
        // this repository's unborn HEAD at the requested branch immediately.
        try withRawRepository(at: root) { rawRepository in
            try Self.check(
                git_repository_set_head(rawRepository, "refs/heads/\(branchName)"),
                operation: "set initial branch"
            )
        }
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
        let recoveryFolder = Self.recoveryFolder(at: root)
        let stagedTargets: [String]
        if includeStaged {
            let repository = try Repository.open(at: root)
            let staged = try Self.stagedPaths(in: repository)
            stagedTargets = safe.filter { staged.contains($0) }
        } else {
            stagedTargets = []
        }
        var recovered = try writeRecoveryCopy(paths: safe, at: root, folder: recoveryFolder)
        if !stagedTargets.isEmpty {
            recovered = (try writeIndexRecovery(paths: stagedTargets, at: root, folder: recoveryFolder)) || recovered
            // Reset the index entries to HEAD first; a staged addition then
            // falls back to "untracked" and a staged deletion to "tracked".
            try unstage(paths: stagedTargets, at: root)
        }

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
            try? FileManager.default.removeItem(at: url)
        }
        return GitDiscardOutcome(discardedPaths: safe, recoveryPath: recovered ? recoveryFolder.path : nil)
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
        try configure(repository, authorName: authorName, authorEmail: authorEmail)
        let commit = try repository.commit(message: value)
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
    }

    public func clone(from remoteURL: URL, to destination: URL, token: String?) throws {
        try Self.validateRemote(remoteURL)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw FloeError.validationFailed("Clone destination already exists")
        }
        try withRuntime {
            var options = git_clone_options()
            try Self.check(git_clone_options_init(&options, UInt32(GIT_CLONE_OPTIONS_VERSION)), operation: "initialize clone")
            let payload = CredentialPayload(token: token)
            try Self.withPayload(payload) { pointer in
                options.fetch_opts.callbacks.credentials = Self.credentialsCallback
                options.fetch_opts.callbacks.payload = pointer
                var repository: OpaquePointer?
                let result = git_clone(&repository, remoteURL.absoluteString, destination.path, &options)
                git_repository_free(repository)
                if result < 0 {
                    try? FileManager.default.removeItem(at: destination)
                }
                try Self.check(result, operation: "clone repository")
            }
        }
    }

    public func fetch(at root: URL, token: String?) throws {
        try authenticatedRemoteOperation(at: root, token: token, operation: "fetch") { remote, callbacks in
            var options = git_fetch_options()
            try Self.check(git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION)), operation: "initialize fetch")
            options.callbacks = callbacks
            try Self.check(git_remote_fetch(remote, nil, &options, nil), operation: "fetch")
        }
    }

    public func push(at root: URL, token: String?) throws {
        try authenticatedRemoteOperation(at: root, token: token, operation: "push") { remote, callbacks in
            let repository = git_remote_owner(remote)
            guard let repository else { throw FloeError.internalError("Git remote has no repository") }
            var head: OpaquePointer?
            try Self.check(git_repository_head(&head, repository), operation: "resolve current branch")
            guard let head, let rawName = git_reference_name(head) else {
                git_reference_free(head)
                throw FloeError.validationFailed("Git HEAD is detached")
            }
            defer { git_reference_free(head) }
            let name = String(cString: rawName)
            let refspec = "\(name):\(name)"
            var options = git_push_options()
            try Self.check(git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION)), operation: "initialize push")
            options.callbacks = callbacks
            try refspec.withCString { rawRefspec in
                var mutable: UnsafeMutablePointer<CChar>? = UnsafeMutablePointer(mutating: rawRefspec)
                try withUnsafeMutablePointer(to: &mutable) { strings in
                    var values = git_strarray(strings: strings, count: 1)
                    try Self.check(git_remote_push(remote, &values, &options), operation: "push")
                }
            }
        }
    }

    /// Fetches then performs a fast-forward-only update. Dirty workspaces and
    /// diverged histories are left untouched and surfaced to the caller.
    public func pullFastForward(at root: URL, token: String?) throws {
        let before = try Repository.open(at: root)
        guard try before.status().isEmpty else {
            throw FloeError.validationFailed("Commit workspace changes before pulling")
        }
        try fetch(at: root, token: token)
        let repository = try Repository.open(at: root)
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
    }

    // MARK: - Merge and conflict resolution

    /// Merges `refName` (a full ref such as `refs/heads/feature`) into the
    /// current branch. Fast-forwards when possible; otherwise performs a real
    /// merge and leaves conflicted paths for explicit resolution. Force-push
    /// and rebase are deliberately not implemented.
    @discardableResult
    public func mergeRef(at root: URL, refName: String, authorName: String, authorEmail: String) throws -> GitMergeOutcome {
        try configure(Repository.open(at: root), authorName: authorName, authorEmail: authorEmail)
        return try withRawRepository(at: root) { repository in
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
                return GitMergeOutcome(result: .upToDate, message: "已经是最新")
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
                return GitMergeOutcome(result: .fastForward, message: "已快进合并")
            }
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
                    message: "合并存在冲突，请逐个解决后提交",
                    conflictedPaths: conflicts
                )
            }
            try Self.createMergeCommit(raw: repository, message: (try? Self.mergeMessage(at: root)) ?? "Merge")
            return GitMergeOutcome(result: .merged, message: "合并完成")
        }
    }

    /// Fetches and merges the current branch's configured upstream. This is
    /// the ordinary pull with a merge fallback; it never rewrites local
    /// commits (no rebase, no force).
    @discardableResult
    public func pullMerge(at root: URL, token: String?, authorName: String, authorEmail: String) throws -> GitMergeOutcome {
        try fetch(at: root, token: token)
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
    public func resolveConflict(at root: URL, path: String, content: String, authorName: String, authorEmail: String) throws -> GitMergeOutcome {
        let safe = try Self.validRelativePath(path)
        try configure(Repository.open(at: root), authorName: authorName, authorEmail: authorEmail)
        return try withRawRepository(at: root) { repository in
            let url = root.appendingPathComponent(safe).standardizedFileURL
            guard url.path.hasPrefix(root.standardizedFileURL.path + "/") else {
                throw FloeError.validationFailed("Git path must stay inside the workspace")
            }
            try Data(content.utf8).write(to: url, options: .atomic)
            var index: OpaquePointer?
            try Self.check(git_repository_index(&index, repository), operation: "open index")
            guard let index else { throw FloeError.internalError("Git index is unavailable") }
            defer { git_index_free(index) }
            try Self.check(git_index_add_bypath(index, safe), operation: "stage resolved path")
            try Self.check(git_index_write(index), operation: "write index")
            let remaining = try Self.conflictedPaths(raw: repository)
            guard remaining.isEmpty else {
                return GitMergeOutcome(
                    result: .conflicts,
                    message: "仍有未解决的冲突",
                    conflictedPaths: remaining
                )
            }
            try Self.createMergeCommit(
                raw: repository,
                message: (try? Self.mergeMessage(at: root)) ?? "Merge"
            )
            return GitMergeOutcome(result: .merged, message: "冲突已解决，合并完成")
        }
    }

    /// Returns the repository to its pre-merge state. Local commits are kept
    /// (hard reset to HEAD, never to a remote).
    public func abortMerge(at root: URL) throws {
        try withRawRepository(at: root) { repository in
            try Self.check(git_repository_state_cleanup(repository), operation: "clean merge state")
            var oid = git_oid()
            try Self.check(git_reference_name_to_id(&oid, repository, "HEAD"), operation: "resolve HEAD")
            var object: OpaquePointer?
            try Self.check(git_object_lookup(&object, repository, &oid, GIT_OBJECT_COMMIT), operation: "lookup HEAD commit")
            guard let object else { throw FloeError.internalError("Git HEAD commit is unavailable") }
            defer { git_object_free(object) }
            try Self.check(git_reset(repository, object, GIT_RESET_HARD, nil), operation: "abort merge")
        }
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
    private func writeRecoveryCopy(paths: [String], at root: URL, folder: URL) throws -> Bool {
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
    private func writeIndexRecovery(paths: [String], at root: URL, folder: URL) throws -> Bool {
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
                guard let content = git_blob_rawcontent(blob) else { continue }
                let data = Data(bytes: content, count: Int(git_blob_rawsize(blob)))
                let destination = folder.appendingPathComponent(path + ".staged")
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
                copied = true
            }
            return copied
        }
    }

    private func configure(_ repository: Repository, authorName: String, authorEmail: String) throws {
        let name = authorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = authorEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200,
              email.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil else {
            throw FloeError.validationFailed("Git author name or email is invalid")
        }
        try repository.config.set("user.name", to: name)
        try repository.config.set("user.email", to: email)
    }

    private func authenticatedRemoteOperation(
        at root: URL,
        token: String?,
        operation: String,
        body: (OpaquePointer, git_remote_callbacks) throws -> Void
    ) throws {
        try withRuntime {
            try withRawRepository(at: root) { repository in
                var remote: OpaquePointer?
                try Self.check(git_remote_lookup(&remote, repository, "origin"), operation: "resolve origin")
                guard let remote else { throw FloeError.validationFailed("Git origin remote is missing") }
                defer { git_remote_free(remote) }
                if let rawURL = git_remote_url(remote), let url = URL(string: String(cString: rawURL)) {
                    try Self.validateRemote(url)
                }
                let payload = CredentialPayload(token: token)
                try Self.withPayload(payload) { pointer in
                    var callbacks = git_remote_callbacks()
                    try Self.check(
                        git_remote_init_callbacks(&callbacks, UInt32(GIT_REMOTE_CALLBACKS_VERSION)),
                        operation: "initialize \(operation) authentication"
                    )
                    callbacks.credentials = Self.credentialsCallback
                    callbacks.payload = pointer
                    try body(remote, callbacks)
                }
            }
        }
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

    private static func change(from entry: SwiftGitX.StatusEntry) -> GitFileChange? {
        let delta = entry.workingTree ?? entry.index
        guard let delta else { return nil }
        let statuses = entry.status
        let kind: GitChangeKind
        if statuses.contains(where: { if case .conflicted = $0 { true } else { false } }) { kind = .conflicted }
        else if statuses.contains(where: { if case .workingTreeNew = $0 { true } else { false } }) { kind = .untracked }
        else if statuses.contains(where: {
            if case .indexNew = $0 { true } else { false }
        }) { kind = .added }
        else if statuses.contains(where: {
            if case .workingTreeDeleted = $0 { true } else if case .indexDeleted = $0 { true } else { false }
        }) { kind = .deleted }
        else if statuses.contains(where: {
            if case .workingTreeRenamed = $0 { true } else if case .indexRenamed = $0 { true } else { false }
        }) { kind = .renamed }
        else if statuses.contains(where: {
            if case .workingTreeTypeChange = $0 { true } else if case .indexTypeChange = $0 { true } else { false }
        }) { kind = .typeChanged }
        else { kind = .modified }
        let staged = statuses.contains {
            switch $0 {
            case .indexNew, .indexModified, .indexDeleted, .indexRenamed, .indexTypeChange: true
            default: false
            }
        }
        let path = kind == .deleted ? delta.oldFile.path : delta.newFile.path
        let oldPath = kind == .renamed ? delta.oldFile.path : nil
        return GitFileChange(path: path, oldPath: oldPath, kind: kind, staged: staged)
    }

    private static func validRelativePath(_ path: String) throws -> String {
        let value = path.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("/"), !value.split(separator: "/").contains(".."),
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

    private static func validateRemote(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              host == "github.com" || host.hasSuffix(".github.com") else {
            throw FloeError.validationFailed("目前仅支持通过 HTTPS 连接 GitHub 仓库")
        }
        guard url.user == nil, url.password == nil else {
            throw FloeError.validationFailed("仓库地址不能包含账号或凭据，请在 GitHub 连接中单独保存")
        }
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

    private final class CredentialPayload: @unchecked Sendable {
        let token: String?
        init(token: String?) { self.token = token }
    }

    private static func withPayload<T>(_ payload: CredentialPayload, _ body: (UnsafeMutableRawPointer) throws -> T) throws -> T {
        let retained = Unmanaged.passRetained(payload)
        defer { retained.release() }
        return try body(retained.toOpaque())
    }

    private static let credentialsCallback: git_credential_acquire_cb = { output, _, _, allowed, rawPayload in
        guard let output, let rawPayload else { return GIT_EUSER.rawValue }
        let payload = Unmanaged<CredentialPayload>.fromOpaque(rawPayload).takeUnretainedValue()
        guard let token = payload.token, !token.isEmpty,
              allowed & GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue != 0 else {
            return GIT_PASSTHROUGH.rawValue
        }
        return git_credential_userpass_plaintext_new(output, "x-access-token", token)
    }
}
