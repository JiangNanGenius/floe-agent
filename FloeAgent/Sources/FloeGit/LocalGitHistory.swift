// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import libgit2

public struct GitCommitDetails: Codable, Sendable, Equatable {
    public let oid: String
    public let message: String
    public let author: String
    public let date: Date
    public let parentOIDs: [String]
    /// First-parent patch, or the empty tree for a root commit.
    public let diff: String
    public let diffTruncated: Bool
}
private final class GitHistoryPatchBuffer {
    var bytes = Data()
    var truncated = false
    static let maximumBytes = 2_097_152
    func append(_ line: git_diff_line) -> Int32 {
        if Task.isCancelled { return GIT_EUSER.rawValue }
        guard let content = line.content else { return 0 }
        let origin = UInt8(bitPattern: line.origin)
        let prefix = [UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: " ")].contains(origin) ? 1 : 0
        guard line.content_len <= Self.maximumBytes - bytes.count - prefix else { truncated = true; return GIT_EUSER.rawValue }
        if prefix == 1 { bytes.append(origin) }
        bytes.append(UnsafeBufferPointer(start: UnsafeRawPointer(content).assumingMemoryBound(to: UInt8.self), count: line.content_len))
        return 0
    }
}
extension LocalGitService {
    public func remoteBranches(at root: URL, remote: String) throws -> [String] {
        try GitNativeRemoteDriver.validRemoteName(remote)
        return try GitNativeRemoteDriver.runtime {
            try GitNativeRemoteDriver.repository(root) { repository in
                var iterator: OpaquePointer?
                try GitNativeRemoteDriver.check(git_branch_iterator_new(&iterator, repository, GIT_BRANCH_REMOTE))
                guard let iterator else { throw FloeError.notFound("branch iterator") }; defer { git_branch_iterator_free(iterator) }
                var names = [String](), ref: OpaquePointer?, type = GIT_BRANCH_REMOTE
                while git_branch_next(&ref, &type, iterator) == 0 {
                    if let ref {
                        defer { git_reference_free(ref) }
                        var name: UnsafePointer<CChar>?
                        try GitNativeRemoteDriver.check(git_branch_name(&name, ref))
                        if let name {
                            let value = String(cString: name), prefix = remote + "/"
                            if value.hasPrefix(prefix), value != prefix + "HEAD" { names.append(String(value.dropFirst(prefix.count))) }
                        }
                    }
                    ref = nil
                }
                return names.sorted()
            }
        }
    }
    public func commitDetails(at root: URL, oid: String) throws -> GitCommitDetails {
        guard [40, 64].contains(oid.utf8.count), oid.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw FloeError.validationFailed(FloeL10n.isChinese ? "请选择一个实际提交。" : "Choose an existing commit.")
        }
        try Task.checkCancellation()
        return try GitNativeRemoteDriver.runtime {
            try GitNativeRemoteDriver.repository(root) { repository in
                var objectID = git_oid(), commit: OpaquePointer?
                try GitNativeRemoteDriver.check(git_oid_fromstr(&objectID, oid))
                try GitNativeRemoteDriver.check(git_commit_lookup(&commit, repository, &objectID))
                guard let commit else { throw FloeError.notFound("commit") }; defer { git_commit_free(commit) }
                var currentTree: OpaquePointer?, previousTree: OpaquePointer?, parent: OpaquePointer?
                try GitNativeRemoteDriver.check(git_commit_tree(&currentTree, commit)); defer { git_tree_free(currentTree) }
                let count = git_commit_parentcount(commit)
                var parents = [String]()
                for number in 0..<count { if let id = git_commit_parent_id(commit, number) { parents.append(Self.oidText(id)) } }
                if count > 0 {
                    try GitNativeRemoteDriver.check(git_commit_parent(&parent, commit, 0))
                    guard let parent else { throw FloeError.notFound("parent commit") }
                    try GitNativeRemoteDriver.check(git_commit_tree(&previousTree, parent)); git_commit_free(parent)
                }
                defer { git_tree_free(previousTree) }
                var options = git_diff_options(), diff: OpaquePointer?
                try GitNativeRemoteDriver.check(git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION)))
                options.flags = UInt32(GIT_DIFF_INCLUDE_TYPECHANGE.rawValue); options.max_size = 16_777_216
                try GitNativeRemoteDriver.check(git_diff_tree_to_tree(&diff, repository, previousTree, currentTree, &options))
                guard let diff else { throw FloeError.notFound("commit diff") }; defer { git_diff_free(diff) }
                let buffer = GitHistoryPatchBuffer()
                let status = git_diff_print(diff, GIT_DIFF_FORMAT_PATCH, { _, _, line, payload in
                    guard let line, let payload else { return GIT_EUSER.rawValue }
                    return Unmanaged<GitHistoryPatchBuffer>.fromOpaque(payload).takeUnretainedValue().append(line.pointee)
                }, Unmanaged.passUnretained(buffer).toOpaque())
                try Task.checkCancellation()
                if !buffer.truncated { try GitNativeRemoteDriver.check(status) }
                let signature = git_commit_author(commit)?.pointee
                return .init(oid: oid, message: git_commit_message(commit).map { String(cString: $0) } ?? "",
                    author: signature?.name.map { String(cString: $0) } ?? "", date: Date(timeIntervalSince1970: TimeInterval(git_commit_time(commit))),
                    parentOIDs: parents, diff: String(decoding: buffer.bytes, as: UTF8.self), diffTruncated: buffer.truncated)
            }
        }
    }
}
