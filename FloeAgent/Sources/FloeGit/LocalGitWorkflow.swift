// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import libgit2
import SwiftGitX

public struct GitConflictSnapshot: Codable, Sendable, Equatable {
    public let path: String
    public let headOID: String?
    public let indexRevision: String
    public let worktreeSHA256: String?
    public let base: String?
    public let ours: String?
    public let theirs: String?
    public let result: String
}

extension LocalGitService {
    private static func workflowText(_ english: String, _ chinese: String) -> String { FloeL10n.isChinese ? chinese : english }
    static func oidText(_ pointer: UnsafePointer<git_oid>) -> String {
        var bytes = [CChar](repeating: 0, count: 65)
        git_oid_tostr(&bytes, bytes.count, pointer)
        return String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    public func headRevision(at root: URL) throws -> String? {
        try GitNativeRemoteDriver.runtime {
            try GitNativeRemoteDriver.repository(root) { repository in
                var oid = git_oid()
                let status = git_reference_name_to_id(&oid, repository, "HEAD")
                if status == GIT_ENOTFOUND.rawValue || status == GIT_EUNBORNBRANCH.rawValue { return nil }
                try GitNativeRemoteDriver.check(status); return Self.oidText(&oid)
            }
        }
    }
    /// Does not call write_tree or change the object database. Includes staged
    /// modes/conflict stages so a model's stale staged selection cannot commit.
    public func indexRevision(at root: URL) throws -> String {
        try GitNativeRemoteDriver.runtime {
            try GitNativeRemoteDriver.repository(root) { repository in
                var pointer: OpaquePointer?
                try GitNativeRemoteDriver.check(git_repository_index(&pointer, repository))
                guard let index = pointer else { throw FloeError.notFound("Git index") }; defer { git_index_free(index) }
                var values = [String]()
                for offset in 0..<git_index_entrycount(index) {
                    guard let entry = git_index_get_byindex(index, offset), let path = entry.pointee.path else { throw FloeError.storageCorrupted("Git index entry") }
                    var oid = entry.pointee.id
                    values.append(String(cString: path)); values.append(Self.oidText(&oid))
                    values.append(String(entry.pointee.mode)); values.append(String((entry.pointee.flags >> 12) & 3))
                }
                return FloeDigest.sha256Hex(try JSONEncoder().encode(values))
            }
        }
    }
    @discardableResult
    public func commitChecked(at root: URL, paths: [String], expectedIndexRevision: String, expectedHeadOID: String?,
                              message: String, authorName: String, authorEmail: String) throws -> GitCommitSummary {
        guard !paths.isEmpty, Set(paths).count == paths.count, try indexRevision(at: root) == expectedIndexRevision,
              try headRevision(at: root) == expectedHeadOID else {
            throw FloeError.validationFailed(Self.workflowText("The staged selection changed. Review it before committing.", "暂存内容已变化，请核对后再提交。"))
        }
        let snapshot = try snapshot(at: root)
        var staged = Set<String>()
        for change in snapshot.changes where change.staged {
            staged.insert(change.path); if let old = change.oldPath { staged.insert(old) }
        }
        guard !snapshot.changes.contains(where: { $0.kind == .conflicted }), staged == Set(paths) else {
            throw FloeError.validationFailed(Self.workflowText("Other staged changes or unresolved conflicts remain. Choose the intended files before committing.", "暂存区包含其他更改或尚未解决的冲突，请先确认本次提交的文件。"))
        }
        return try commit(at: root, message: message, authorName: authorName, authorEmail: authorEmail)
    }
    public func upstreamRemote(at root: URL) throws -> String? {
        try GitNativeRemoteDriver.runtime {
            try GitNativeRemoteDriver.repository(root) { repository in
                var pointer: OpaquePointer?
                let found = git_repository_head(&pointer, repository)
                if found == GIT_EUNBORNBRANCH.rawValue || found == GIT_ENOTFOUND.rawValue { return nil }
                try GitNativeRemoteDriver.check(found)
                guard let head = pointer, let name = git_reference_name(head), git_reference_is_branch(head) == 1 else { git_reference_free(pointer); return nil }
                defer { git_reference_free(head) }
                var value = git_buf(); defer { git_buf_dispose(&value) }
                let status = git_branch_upstream_remote(&value, repository, name)
                if status == GIT_ENOTFOUND.rawValue { return nil }
                try GitNativeRemoteDriver.check(status); return value.ptr.map { String(cString: $0) }
            }
        }
    }
    public func setUpstream(at root: URL, branch: String, remote: String, remoteBranch: String) throws {
        try GitNativeRemoteDriver.runtime {
            try GitNativeRemoteDriver.validRemoteName(remote)
            try GitNativeRemoteDriver.repository(root) { repository in
                var pointer: OpaquePointer?
                try GitNativeRemoteDriver.check(git_branch_lookup(&pointer, repository, branch, GIT_BRANCH_LOCAL))
                guard let branch = pointer else { throw FloeError.notFound("branch") }; defer { git_reference_free(branch) }
                try GitNativeRemoteDriver.check(git_branch_set_upstream(branch, remote + "/" + remoteBranch))
            }
        }
        postRepositoryDidChange(at: root)
    }
    public func pull(at root: URL, remoteName: String, authentication: GitRemoteAuthentication, merge: Bool,
                     authorName: String, authorEmail: String, progress: (@Sendable (GitRemoteProgress) -> Void)? = nil) async throws -> GitMergeOutcome {
        let before = try snapshot(at: root), head = try headRevision(at: root)
        guard before.changes.isEmpty, try upstreamRemote(at: root) == remoteName else {
            throw FloeError.validationFailed(Self.workflowText("Save your changes and choose this branch's upstream remote before pulling.", "请先保存本地更改，并选择当前分支的跟踪远端后再拉取。"))
        }
        try await fetch(at: root, remoteName: remoteName, authentication: authentication, progress: progress)
        let after = try snapshot(at: root)
        guard after.changes.isEmpty, after.branch == before.branch, try headRevision(at: root) == head else {
            throw FloeError.validationFailed(Self.workflowText("The local branch changed during fetch. Review it before pulling.", "获取期间本地分支已有变化，请核对后再拉取。"))
        }
        let repository = try Repository.open(at: root), current = try repository.branch.current
        guard let upstream = current.upstream as? Branch, let commit = upstream.target as? Commit,
              let local = current.target as? Commit else { throw FloeError.validationFailed(Self.workflowText("Set an upstream branch to continue.", "请先设置跟踪分支。")) }
        if commit.id == local.id { return .init(result: .upToDate, message: Self.workflowText("Already up to date.", "已是最新。")) }
        if merge { return try mergeRef(at: root, refName: "refs/remotes/" + upstream.name, authorName: authorName, authorEmail: authorEmail) }
        let canFastForward = try GitNativeRemoteDriver.runtime {
            try GitNativeRemoteDriver.repository(root) { raw in
                var a = git_oid(), b = git_oid()
                try GitNativeRemoteDriver.check(git_oid_fromstr(&a, commit.id.hex)); try GitNativeRemoteDriver.check(git_oid_fromstr(&b, local.id.hex))
                let value = git_graph_descendant_of(raw, &a, &b); try GitNativeRemoteDriver.check(value); return value == 1
            }
        }
        guard canFastForward else { throw FloeError.validationFailed(Self.workflowText("These branches diverged. Choose Pull and Merge to keep both histories.", "分支已分叉，可选择“拉取并合并”保留双方历史。")) }
        try repository.reset(to: commit, mode: .hard); postRepositoryDidChange(at: root)
        return .init(result: .fastForward, message: Self.workflowText("Updated to the upstream branch.", "已更新到跟踪分支。"))
    }
    public func conflict(at root: URL, path: String) throws -> GitConflictSnapshot {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains(".."), path != ".git", !path.hasPrefix(".git/") else { throw FloeError.validationFailed("Invalid conflict path") }
        let file = root.appendingPathComponent(path).standardizedFileURL
        guard file.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw FloeError.unauthorized }
        let info = try? file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard info?.isSymbolicLink != true, (info?.fileSize ?? 0) <= 1_048_576 else { throw FloeError.validationFailed(Self.workflowText("This conflict cannot be edited as text. Keep a file version instead.", "此冲突无法作为文本编辑，请选择保留的文件版本。")) }
        let worktree = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        return try GitNativeRemoteDriver.runtime {
            try GitNativeRemoteDriver.repository(root) { repository in
                var pointer: OpaquePointer?
                try GitNativeRemoteDriver.check(git_repository_index(&pointer, repository))
                guard let index = pointer else { throw FloeError.notFound("index") }; defer { git_index_free(index) }
                func text(_ stage: Int32) throws -> String? {
                    guard let entry = git_index_get_bypath(index, path, stage) else { return nil }
                    var oid = entry.pointee.id, pointer: OpaquePointer?
                    try GitNativeRemoteDriver.check(git_blob_lookup(&pointer, repository, &oid))
                    guard let blob = pointer else { throw FloeError.notFound("blob") }; defer { git_blob_free(blob) }
                    guard git_blob_rawsize(blob) <= 1_048_576 else { throw FloeError.validationFailed("Conflict text exceeds the editor limit") }
                    let data = git_blob_rawcontent(blob).map { Data(bytes: $0, count: Int(git_blob_rawsize(blob))) } ?? Data()
                    guard !data.contains(0), let value = String(data: data, encoding: .utf8) else { throw FloeError.validationFailed("Binary conflict") }; return value
                }
                let base = try text(1), ours = try text(2), theirs = try text(3)
                guard base != nil || ours != nil || theirs != nil else { throw FloeError.validationFailed("The conflict was already resolved") }
                let result = worktree.flatMap { String(data: $0, encoding: .utf8) } ?? ours ?? theirs ?? ""
                return .init(path: path, headOID: try headRevision(at: root), indexRevision: try indexRevision(at: root),
                             worktreeSHA256: worktree.map(FloeDigest.sha256Hex), base: base, ours: ours, theirs: theirs, result: result)
            }
        }
    }
    @discardableResult
    public func resolveConflict(at root: URL, expected: GitConflictSnapshot, content: String?, authorName: String, authorEmail: String) throws -> GitMergeOutcome {
        let actual = try conflict(at: root, path: expected.path)
        guard actual == expected, !(content ?? "").split(separator: "\n", omittingEmptySubsequences: false).contains(where: { $0.hasPrefix("<<<<<<<") || $0.hasPrefix(">>>>>>>") }) else {
            throw FloeError.validationFailed(Self.workflowText("This conflict changed or still contains conflict markers. Review it before finishing.", "此冲突已有变化或仍有冲突标记，请核对后完成合并。"))
        }
        return try resolveConflict(at: root, path: expected.path, content: content, authorName: authorName, authorEmail: authorEmail)
    }
}
