// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import libgit2
#if canImport(Darwin)
import Darwin
#endif

public struct GitRemoteDescriptor: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let fetch: GitRemoteEndpoint
    public let push: GitRemoteEndpoint
}
public struct GitCloneReceipt: Sendable, Equatable {
    public let destination: URL
    public let defaultBranch: String?
}
public struct GitCloneRecoveryError: Error, Sendable, LocalizedError {
    public let recoveryDirectory: URL
    public let wasCancelled: Bool
    public let reason: String
    /// Typed native cause lets the existing host-trust flow continue without
    /// parsing localized text or discarding retained partial bytes.
    public let remoteFailure: GitRemoteFailure?
    public var errorDescription: String? {
        if wasCancelled { return FloeL10n.isChinese ? "已取消克隆，下载的内容已保留，可在恢复详情中查看。" : "Clone cancelled. Downloaded content was retained in recovery details." }
        return FloeL10n.isChinese ? "克隆未完成，已保留下载的内容。请检查连接后重试。" : "Clone did not finish. Downloaded content was retained. Check the connection before retrying."
    }
}

/// Synchronous C ownership stays inside the existing LocalGitService actor.
/// The separate cancellation handler can safely stop only this borrowed remote.
enum GitNativeRemoteDriver {
    static func check(_ value: Int32) throws {
        guard value >= 0 else {
            let message = git_error_last()?.pointee.message.map { String(cString: $0) } ?? "Git transfer failed"
            throw FloeError.syncUnavailable(SecretRedactor.redact(message))
        }
    }
    static func validRemoteName(_ value: String) throws {
        var valid: Int32 = 0
        try check(git_remote_name_is_valid(&valid, value))
        guard valid == 1 else { throw FloeError.validationFailed("Invalid remote name") }
    }
    static func runtime<Result>(_ operation: () throws -> Result) throws -> Result {
        try check(git_libgit2_init()); defer { git_libgit2_shutdown() }; return try operation()
    }
    static func repository<Result>(_ root: URL, _ operation: (OpaquePointer) throws -> Result) throws -> Result {
        var pointer: OpaquePointer?
        try check(git_repository_open(&pointer, root.path))
        guard let repository = pointer else { throw FloeError.notFound("repository") }
        defer { git_repository_free(repository) }; return try operation(repository)
    }
    static func endpoint(_ repository: OpaquePointer, name: String, pushing: Bool) throws -> GitRemoteEndpoint {
        var pointer: OpaquePointer?
        try check(git_remote_lookup(&pointer, repository, name))
        guard let remote = pointer else { throw FloeError.notFound("remote") }
        defer { git_remote_free(remote) }
        guard let url = (pushing ? git_remote_pushurl(remote) : nil) ?? git_remote_url(remote) else { throw GitRemoteFailure.invalidAddress }
        return try GitRemoteEndpoint(String(cString: url))
    }
    static func remote<Result>(_ repository: OpaquePointer, name: String, context: GitNativeRemoteContext, pushing: Bool, _ operation: (OpaquePointer) throws -> Result) throws -> Result {
        try context.ensureActive()
        let current = try endpoint(repository, name: name, pushing: pushing)
        guard current == context.authentication.endpoint else { throw GitRemoteFailure.credentialHostMismatch }
        try GitNativeRemoteContext.requireNativeSSH(for: current)
        var pointer: OpaquePointer?
        try check(git_remote_lookup(&pointer, repository, name))
        guard let remote = pointer else { throw FloeError.notFound("remote") }
        context.register(remote: remote)
        defer { context.unregister(remote: remote); git_remote_free(remote) }
        if pushing { try check(git_remote_set_instance_pushurl(remote, current.nativeTransportURL)) }
        else { try check(git_remote_set_instance_url(remote, current.nativeTransportURL)) }
        return try operation(remote)
    }
    static func fetch(_ root: URL, name: String, context: GitNativeRemoteContext) throws {
        try runtime {
            try repository(root) { repository in
                try remote(repository, name: name, context: context, pushing: false) { remote in
                    let status = try context.withCallbacks { callbacks in
                        var options = git_fetch_options()
                        try check(git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION)))
                        options.callbacks = callbacks
                        return git_remote_fetch(remote, nil, &options, nil)
                    }
                    try context.throwRecordedFailure(); try check(status)
                }
            }
        }
    }
    static func push(_ root: URL, name: String, destinationBranch: String?, context: GitNativeRemoteContext) throws {
        try runtime {
            try repository(root) { repository in
                try remote(repository, name: name, context: context, pushing: true) { remote in
                    var pointer: OpaquePointer?
                    try check(git_repository_head(&pointer, repository))
                    guard let head = pointer, git_reference_is_branch(head) == 1, let rawName = git_reference_name(head) else { git_reference_free(pointer); throw FloeError.validationFailed("Select a local branch before pushing") }
                    defer { git_reference_free(head) }
                    let localRef = String(cString: rawName)
                    let target: String
                    if let branch = destinationBranch {
                        var valid: Int32 = 0
                        try check(git_reference_name_is_valid(&valid, "refs/heads/" + branch))
                        guard valid == 1, !branch.hasPrefix("-") else { throw FloeError.validationFailed("Invalid destination branch") }
                        target = "refs/heads/" + branch
                    } else {
                        var upstreamRemote = git_buf(), upstream = git_buf()
                        defer { git_buf_dispose(&upstreamRemote); git_buf_dispose(&upstream) }
                        let configured = git_branch_upstream_remote(&upstreamRemote, repository, localRef)
                        if configured == GIT_ENOTFOUND.rawValue { target = localRef }
                        else {
                            try check(configured); try check(git_branch_upstream_name(&upstream, repository, localRef))
                            guard let remoteName = upstreamRemote.ptr.map({ String(cString: $0) }), remoteName == name,
                                  let upstreamName = upstream.ptr.map({ String(cString: $0) }), upstreamName.hasPrefix("refs/remotes/" + name + "/") else { throw FloeError.validationFailed("Choose the current branch's upstream remote before pushing") }
                            target = "refs/heads/" + String(upstreamName.dropFirst(("refs/remotes/" + name + "/").count))
                        }
                    }
                    let refspec = localRef + ":" + target
                    let status = try context.withCallbacks { callbacks in
                        var options = git_push_options()
                        try check(git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION)))
                        options.callbacks = callbacks
                        return refspec.withCString { value in
                            var raw: UnsafeMutablePointer<CChar>? = UnsafeMutablePointer(mutating: value)
                            return withUnsafeMutablePointer(to: &raw) { strings in
                                var specs = git_strarray(strings: strings, count: 1)
                                return git_remote_push(remote, &specs, &options)
                            }
                        }
                    }
                    if (status < 0 || context.isCancelled) && context.transmittedBytes > 0 {
                        if context.failure == .remoteRejected { throw GitRemoteFailure.remoteRejected }
                        throw GitRemoteFailure.remoteOutcomeUnknown
                    }
                    try context.throwRecordedFailure(); try check(status)
                }
            }
        }
    }
    static func clone(to destination: URL, context: GitNativeRemoteContext) throws -> GitCloneReceipt {
        try context.ensureActive()
        guard destination.isFileURL, !FileManager.default.fileExists(atPath: destination.path) else { throw FloeError.validationFailed("Clone destination already exists") }
        let parent = destination.deletingLastPathComponent()
        let parentInfo = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parentInfo.isDirectory == true, parentInfo.isSymbolicLink != true,
              !["", ".", ".."].contains(destination.lastPathComponent) else { throw FloeError.validationFailed("Choose a folder for the clone") }
        let staging = parent.appendingPathComponent(".floe-clone-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            let branch = try runtime { () -> String? in
                let endpoint = context.authentication.endpoint
                try GitNativeRemoteContext.requireNativeSSH(for: endpoint)
                var pointer: OpaquePointer?
                try check(git_repository_init(&pointer, staging.path, 0))
                guard let repo = pointer else { throw FloeError.notFound("clone repository") }
                defer { git_repository_free(repo) }
                var remotePointer: OpaquePointer?
                try check(git_remote_create(&remotePointer, repo, "origin", endpoint.nativeTransportURL))
                guard let remote = remotePointer else { throw FloeError.notFound("clone remote") }
                context.register(remote: remote)
                defer { context.unregister(remote: remote); git_remote_free(remote) }
                let status = try context.withCallbacks { callbacks in
                    var options = git_fetch_options()
                    try check(git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION)))
                    options.callbacks = callbacks
                    return git_remote_fetch(remote, nil, &options, nil)
                }
                try context.throwRecordedFailure(); try check(status)
                // Store the safe shareable URI, not credentials or the native
                // parser adaptation. Future fetches adapt the borrowed instance.
                try check(git_remote_set_url(repo, "origin", endpoint.transportURL))
                var defaultName = git_buf(); defer { git_buf_dispose(&defaultName) }
                let found = git_remote_default_branch(&defaultName, remote)
                if found == GIT_ENOTFOUND.rawValue { return nil }
                try check(found)
                guard let raw = defaultName.ptr else { throw FloeError.validationFailed("Remote default branch is unavailable") }
                let full = String(cString: raw)
                guard full.hasPrefix("refs/heads/") else { throw FloeError.validationFailed("Remote default branch is invalid") }
                let short = String(full.dropFirst("refs/heads/".count))
                var remoteRef: OpaquePointer?
                try check(git_reference_lookup(&remoteRef, repo, "refs/remotes/origin/" + short))
                guard let ref = remoteRef, let oid = git_reference_target(ref) else { git_reference_free(remoteRef); throw FloeError.notFound("remote branch") }
                defer { git_reference_free(ref) }
                var commit: OpaquePointer?
                try check(git_commit_lookup(&commit, repo, oid))
                guard let commit else { throw FloeError.notFound("remote commit") }; defer { git_commit_free(commit) }
                var branch: OpaquePointer?
                try check(git_branch_create(&branch, repo, short, commit, 0))
                guard let branch else { throw FloeError.notFound("local branch") }; defer { git_reference_free(branch) }
                try check(git_branch_set_upstream(branch, "origin/" + short))
                try check(git_repository_set_head(repo, full))
                var checkout = git_checkout_options()
                try check(git_checkout_options_init(&checkout, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
                checkout.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
                try context.ensureActive(); try check(git_checkout_head(repo, &checkout)); try context.ensureActive()
                return short
            }
            try context.ensureActive()
            #if canImport(Darwin)
            // Atomic directory publication with explicit no-replace, including
            // a destination created concurrently after the initial check.
            guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            #else
            try FileManager.default.moveItem(at: staging, to: destination)
            #endif
            return .init(destination: destination, defaultBranch: branch)
        } catch {
            throw GitCloneRecoveryError(recoveryDirectory: staging, wasCancelled: context.isCancelled || error is CancellationError,
                                        reason: SecretRedactor.redact(error.localizedDescription), remoteFailure: error as? GitRemoteFailure)
        }
    }
}
