// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import libgit2
public struct GitHistoryPage: Codable, Sendable {
    public let headOID: String?
    public let items: [GitCommitSummary]
    public let nextOffset: Int?
}
public struct GitRemoteCheckoutReceipt: Codable, Sendable {
    public let branch: String
    public let upstream: String
    public let headOID: String
}
public struct GitRemoteCheckoutIncomplete: Error, Sendable, LocalizedError {
    public let createdBranch: String
    public var errorDescription: String? {
        FloeL10n.isChinese ? "分支“\(createdBranch)”已创建，但切换未完成。当前文件与分支均已保留，请刷新后继续。" : "Branch “\(createdBranch)” was created, but switching did not finish. Current files and the branch were retained. Refresh before continuing."
    }
}
extension LocalGitService {
    public func history(at root: URL, offset: Int = 0, limit: Int = 30, expectedHeadOID: String? = nil) throws -> GitHistoryPage {
        guard (0...1_000_000).contains(offset), (1...200).contains(limit), offset == 0 || expectedHeadOID != nil else { throw FloeError.validationFailed("Use a valid history page and copy its headOID when continuing") }
        let head = try headRevision(at: root)
        guard expectedHeadOID == nil || head == expectedHeadOID else {
            throw FloeError.validationFailed(FloeL10n.isChinese ? "提交记录已变化，请刷新后继续。" : "Commit history changed. Refresh before continuing.")
        }
        guard let head else { return .init(headOID: nil, items: [], nextOffset: nil) }
        return try GitNativeRemoteDriver.runtime {
            try GitNativeRemoteDriver.repository(root) { repository in
                var walk: OpaquePointer?
                try GitNativeRemoteDriver.check(git_revwalk_new(&walk, repository))
                guard let walk else { throw FloeError.notFound("Git history") }; defer { git_revwalk_free(walk) }
                git_revwalk_sorting(walk, UInt32(GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue))
                var headID = git_oid(); try GitNativeRemoteDriver.check(git_oid_fromstr(&headID, head))
                try GitNativeRemoteDriver.check(git_revwalk_push(walk, &headID))
                var items = [GitCommitSummary](), seen = 0, oid = git_oid(), hasMore = false
                while true {
                    try Task.checkCancellation()
                    let next = git_revwalk_next(&oid, walk)
                    if next == GIT_ITEROVER.rawValue { break }; try GitNativeRemoteDriver.check(next)
                    if seen < offset { seen += 1; continue }
                    if items.count == limit { hasMore = true; break }
                    var commit: OpaquePointer?
                    try GitNativeRemoteDriver.check(git_commit_lookup(&commit, repository, &oid))
                    guard let commit else { throw FloeError.notFound("Git commit") }; defer { git_commit_free(commit) }
                    let text = Self.oidText(&oid), author = git_commit_author(commit)?.pointee.name.map { String(cString: $0) } ?? ""
                    items.append(.init(oid: text, shortOID: String(text.prefix(8)), message: git_commit_summary(commit).map { String(cString: $0) } ?? "",
                        author: author, date: Date(timeIntervalSince1970: TimeInterval(git_commit_time(commit)))))
                }
                return .init(headOID: head, items: items, nextOffset: hasMore ? offset + items.count : nil)
            }
        }
    }
    /// Uses only an existing fetched remote ref and a new local branch. Never
    /// force-checks out, resets an existing branch, or downloads implicitly.
    public func checkoutRemote(at root: URL, remote: String, remoteBranch: String, localBranch: String) throws -> GitRemoteCheckoutReceipt {
        try GitNativeRemoteDriver.validRemoteName(remote)
        let before = try snapshot(at: root), head = try headRevision(at: root)
        guard before.isRepository, before.changes.isEmpty, !remoteBranch.isEmpty, remoteBranch != "HEAD", !localBranch.isEmpty else {
            throw FloeError.validationFailed(FloeL10n.isChinese ? "请先保存本地更改，并选择一个已获取的远端分支。" : "Save local changes and choose an already fetched remote branch first.")
        }
        return try GitNativeRemoteDriver.runtime {
            try GitNativeRemoteDriver.repository(root) { repository in
                let fullName = "refs/heads/" + localBranch
                var valid: Int32 = 0
                try GitNativeRemoteDriver.check(git_reference_name_is_valid(&valid, fullName))
                guard valid == 1 else { throw FloeError.validationFailed("Invalid local branch name") }
                var remoteRef: OpaquePointer?
                try GitNativeRemoteDriver.check(git_branch_lookup(&remoteRef, repository, remote + "/" + remoteBranch, GIT_BRANCH_REMOTE))
                guard let remoteRef, let target = git_reference_target(remoteRef) else { git_reference_free(remoteRef); throw FloeError.notFound("remote branch") }
                defer { git_reference_free(remoteRef) }
                let oid = Self.oidText(target)
                var object: OpaquePointer?
                try GitNativeRemoteDriver.check(git_commit_lookup(&object, repository, target))
                guard let object else { throw FloeError.notFound("remote commit") }; defer { git_commit_free(object) }
                // Inspect all failure-prone source/target state before creating
                // a branch or touching a file. A taken name is never replaced.
                var existing: OpaquePointer?
                let exists = git_branch_lookup(&existing, repository, localBranch, GIT_BRANCH_LOCAL)
                git_reference_free(existing)
                guard exists == GIT_ENOTFOUND.rawValue else {
                    if exists < 0 { try GitNativeRemoteDriver.check(exists) }
                    throw FloeError.validationFailed(FloeL10n.isChinese ? "本地分支已存在，请选择该分支或使用其他名称。" : "That local branch already exists. Select it or choose another name.")
                }
                guard try snapshot(at: root).changes.isEmpty, try headRevision(at: root) == head else { throw FloeError.validationFailed("The local checkout changed. Refresh before switching.") }
                try Task.checkCancellation()
                var local: OpaquePointer?
                try GitNativeRemoteDriver.check(git_branch_create(&local, repository, localBranch, object, 0))
                guard let local else { throw FloeError.notFound("local branch") }; defer { git_reference_free(local) }
                defer { postRepositoryDidChange(at: root) }
                do {
                    try GitNativeRemoteDriver.check(git_branch_set_upstream(local, remote + "/" + remoteBranch))
                    try Task.checkCancellation()
                    var options = git_checkout_options()
                    try GitNativeRemoteDriver.check(git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
                    options.checkout_strategy = UInt32(GIT_CHECKOUT_SAFE.rawValue)
                    try GitNativeRemoteDriver.check(git_checkout_tree(repository, object, &options))
                    try GitNativeRemoteDriver.check(git_repository_set_head(repository, fullName))
                    return .init(branch: localBranch, upstream: remote + "/" + remoteBranch, headOID: oid)
                } catch { throw GitRemoteCheckoutIncomplete(createdBranch: localBranch) }
            }
        }
    }
}
