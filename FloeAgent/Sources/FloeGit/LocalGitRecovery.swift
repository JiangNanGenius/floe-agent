// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import libgit2

public struct GitRecoveryRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let createdAt: Date
    public let kind: String
    public var completed: Bool
    public var entries: [Entry]
    public struct Entry: Codable, Sendable, Identifiable, Equatable {
        public var id: String { path }
        public let path: String
        public let worktreeBefore: String?
        public let indexBefore: String?
        public let indexMode: UInt32?
        public var worktreeAfter: String?
        public var indexAfter: String?
        public var indexAfterMode: UInt32?
    }
}
public enum GitRecoveryLayer: String, Codable, Sendable { case worktree, index }

extension LocalGitService {
    func recoveryBase(_ root: URL) throws -> URL {
        try GitNativeRemoteDriver.runtime {
            try GitNativeRemoteDriver.repository(root) { repository in
                guard let raw = git_repository_path(repository) else { throw FloeError.notFound("Git directory") }
                return URL(fileURLWithPath: String(cString: raw), isDirectory: true).appendingPathComponent("floe-recovery", isDirectory: true)
            }
        }
    }
    private func recoveryPath(_ path: String, root: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/").contains(".."), path != ".git", !path.hasPrefix(".git/") else { throw FloeError.unauthorized }
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw FloeError.unauthorized }
        if FileManager.default.fileExists(atPath: url.path) {
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else {
                throw FloeError.validationFailed(FloeL10n.isChinese ? "此项不能作为普通文件恢复。" : "This item cannot be restored as a regular file.")
            }
        }
        return url
    }
    private func digest(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try FloeDigest.sha256Hex(ofFileAt: url)
    }
    private func indexState(_ root: URL, path: String, allowConflicts: Bool = false) throws -> (oid: String?, mode: UInt32?) {
        try GitNativeRemoteDriver.runtime {
            try GitNativeRemoteDriver.repository(root) { repository in
                var raw: OpaquePointer?
                try GitNativeRemoteDriver.check(git_repository_index(&raw, repository))
                guard let index = raw else { throw FloeError.notFound("index") }; defer { git_index_free(index) }
                if !allowConflicts && (1...3).contains(where: { git_index_get_bypath(index, path, Int32($0)) != nil }) {
                    throw FloeError.validationFailed("The file has a newer merge conflict")
                }
                guard let entry = git_index_get_bypath(index, path, 0) else { return (nil, nil) }
                var oid = entry.pointee.id; return (Self.oidText(&oid), entry.pointee.mode)
            }
        }
    }
    func captureRecovery(paths: [String], at root: URL, includeIndex: Bool, kind: String = "discard", allowConflicts: Bool = false) throws -> GitRecoveryRecord {
        let id = UUID().uuidString.lowercased(), base = try recoveryBase(root).appendingPathComponent(id, isDirectory: true)
        var entries = [GitRecoveryRecord.Entry]()
        for path in paths {
            try Task.checkCancellation()
            let source = try recoveryPath(path, root: root), before = try digest(source)
            let index = try indexState(root, path: path, allowConflicts: allowConflicts)
            entries.append(.init(path: path, worktreeBefore: before, indexBefore: includeIndex ? index.oid : nil,
                                 indexMode: includeIndex ? index.mode : nil))
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Separate namespaces prevent a real filename foo.staged colliding
        // with the staged backup of foo. Existing legacy folders stay intact.
        _ = try writeRecoveryCopy(paths: paths, at: root, folder: base.appendingPathComponent("worktree"))
        if includeIndex { _ = try writeIndexRecovery(paths: paths, at: root, folder: base.appendingPathComponent("index")) }
        for entry in entries {
            if let sha = entry.worktreeBefore {
                let backup = try recoveryPath(entry.path, root: base.appendingPathComponent("worktree"))
                guard try digest(backup) == sha else { throw FloeError.storageCorrupted("Recovery copy differs") }
            }
        }
        let record = GitRecoveryRecord(id: id, createdAt: Date(), kind: kind, completed: false, entries: entries)
        try JSONEncoder().encode(record).write(to: base.appendingPathComponent("manifest.json"), options: [.atomic])
        return record
    }
    func finishRecovery(_ record: GitRecoveryRecord, at root: URL) throws -> GitRecoveryRecord {
        var completed = record
        for offset in completed.entries.indices {
            let path = completed.entries[offset].path
            completed.entries[offset].worktreeAfter = try digest(recoveryPath(path, root: root))
            let index = try indexState(root, path: path)
            completed.entries[offset].indexAfter = index.oid
            completed.entries[offset].indexAfterMode = index.mode
        }
        completed.completed = true
        let directory = try recoveryBase(root).appendingPathComponent(record.id)
        try JSONEncoder().encode(completed).write(to: directory.appendingPathComponent("manifest.json"), options: [.atomic])
        return completed
    }
    public func recoveries(at root: URL) throws -> [GitRecoveryRecord] {
        let base = try recoveryBase(root)
        guard FileManager.default.fileExists(atPath: base.path) else { return [] }
        let directories = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return try directories.compactMap { directory in
            guard UUID(uuidString: directory.lastPathComponent) != nil,
                  try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { return nil }
            let file = directory.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max <= 1_048_576 else { throw FloeError.storageCorrupted("Recovery manifest too large") }
            let record = try JSONDecoder().decode(GitRecoveryRecord.self, from: Data(contentsOf: file))
            guard record.id == directory.lastPathComponent else { throw FloeError.storageCorrupted("Recovery identity differs") }
            return record
        }.sorted { $0.createdAt > $1.createdAt }
    }
    public func restoreRecovery(at root: URL, id: String, path: String, layer: GitRecoveryLayer) throws {
        guard UUID(uuidString: id) != nil, let record = try recoveries(at: root).first(where: { $0.id == id }), record.completed,
              let entry = record.entries.first(where: { $0.path == path }) else { throw FloeError.validationFailed("Recovery is incomplete or unavailable") }
        let target = try recoveryPath(path, root: root)
        let currentIndex = try indexState(root, path: path), currentWorktree = try digest(target)
        let indexMatches = currentIndex.oid == entry.indexAfter && currentIndex.mode == entry.indexAfterMode
        let alreadyRestoredIndex = currentIndex.oid == entry.indexBefore && currentIndex.mode == entry.indexMode
        let worktreeMatches = currentWorktree == entry.worktreeAfter
        let alreadyRestoredWorktree = currentWorktree == entry.worktreeBefore
        guard (worktreeMatches || (layer == .index && alreadyRestoredWorktree)),
              (indexMatches || (layer == .worktree && alreadyRestoredIndex)) else {
            throw FloeError.validationFailed(FloeL10n.isChinese ? "文件已有新的修改，未覆盖。请先核对当前内容。" : "The file has newer changes. Review them before restoring.")
        }
        let directory = try recoveryBase(root).appendingPathComponent(id)
        if layer == .worktree {
            if let expected = entry.worktreeBefore {
                let source = try recoveryPath(path, root: directory.appendingPathComponent("worktree"))
                guard try digest(source) == expected else { throw FloeError.storageCorrupted("Recovery bytes differ") }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let staged = target.deletingLastPathComponent().appendingPathComponent(".floe-restore-" + UUID().uuidString)
                try FileManager.default.copyItem(at: source, to: staged)
                guard try digest(target) == entry.worktreeAfter else { throw FloeError.validationFailed("File changed during restore") }
                if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: staged) }
                else { try FileManager.default.moveItem(at: staged, to: target) }
            } else if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        } else {
            guard let expected = entry.indexBefore, let mode = entry.indexMode else { throw FloeError.validationFailed("No staged version is stored in this recovery") }
            let source = try recoveryPath(path + ".staged", root: directory.appendingPathComponent("index"))
            let data = try Data(contentsOf: source)
            try GitNativeRemoteDriver.runtime {
                try GitNativeRemoteDriver.repository(root) { repository in
                    var raw: OpaquePointer?
                    try GitNativeRemoteDriver.check(git_repository_index(&raw, repository))
                    guard let index = raw else { throw FloeError.notFound("index") }; defer { git_index_free(index) }
                    var actualOID = git_oid()
                    try data.withUnsafeBytes { bytes in
                        try GitNativeRemoteDriver.check(git_odb_hash(&actualOID, bytes.baseAddress, bytes.count, GIT_OBJECT_BLOB))
                    }
                    guard Self.oidText(&actualOID) == expected else { throw FloeError.storageCorrupted("Staged recovery bytes differ") }
                    try path.withCString { pathPointer in
                        var entry = git_index_entry(); entry.path = pathPointer; entry.mode = mode
                        try data.withUnsafeBytes { bytes in try GitNativeRemoteDriver.check(git_index_add_frombuffer(index, &entry, bytes.baseAddress, bytes.count)) }
                    }
                    try GitNativeRemoteDriver.check(git_index_write(index))
                }
            }
        }
        postRepositoryDidChange(at: root)
    }
}
