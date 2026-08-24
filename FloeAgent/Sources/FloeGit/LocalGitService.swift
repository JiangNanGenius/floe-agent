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
        let requestedPath = try path.map(Self.validRelativePath)
        let diff = try repository.diff(to: [.workingTree, .index])
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
            throw FloeError.validationFailed("This release supports HTTPS GitHub remotes only")
        }
        guard url.user == nil, url.password == nil else {
            throw FloeError.validationFailed("Credentials must not be embedded in a Git remote URL")
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
