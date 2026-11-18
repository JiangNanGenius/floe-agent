// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeGameCore
import FloeWorkspace
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct ExistingGameWorkspaceTarget: Sendable {
    public let binding: GameWorkingTreeBinding
    public let service: WorkspaceFileService
    public let revisions: GameWorkspaceRevisionTracker
    public init(binding: GameWorkingTreeBinding, service: WorkspaceFileService,
                revisions: GameWorkspaceRevisionTracker) throws {
        // Foundation preserves a directory-hint trailing slash in some URLs.
        // Compare canonical components, as the existing IDE root guard does.
        guard binding.rootURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
                == service.guardResolver.rootURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents,
              binding.rootURL == revisions.binding.rootURL,
              binding.projectID == revisions.binding.projectID,
              binding.owner == revisions.binding.owner,
              binding.workspaceID == revisions.binding.workspaceID,
              binding.environmentID == revisions.binding.environmentID else {
            throw GameProjectError.invalidContext
        }
        self.binding = binding; self.service = service; self.revisions = revisions
    }
}

public struct GameWorkingTreeRecoveryRequired: Error, LocalizedError, Sendable {
    public let recoveryDirectory: URL
    public let conflictingPaths: [String]
    public var errorDescription: String? {
        Locale.current.language.languageCode?.identifier == "zh"
            ? "项目修改尚待恢复。原始文件和修改记录已保留。"
            : "The project needs recovery. Original files and edit records were retained."
    }
}

public struct GameWorkingTreeRecoveryReview: Sendable {
    public let id: String
    public let binding: GameWorkingTreeBinding
    public let paths: [String]
    public let retainedOriginals: URL
    fileprivate let snapshot: GameWorkingTreeSnapshot
}

/// Production-facing I/O adapter over the actual existing file service. It
/// uses the existing managed-file lock, guards and Git notification. Immutable
/// game blobs remain history only; every working edit lands in the IDE root.
/// The host must retain its existing security-scoped workspace/job lease.
public final class ExistingWorkspaceGameFiles: GameWorkingTreePort, @unchecked Sendable {
    private let targets: [UUID: ExistingGameWorkspaceTarget]
    private let repositoryDirectory: URL
    private let vcsNames: Set<String> = [".git", ".hg", ".svn"]
    private let lock = ManagedFileMutationLock.shared
    private var activeTransactions: Set<UUID> = []
    // Hints only: every hit is reopened descriptor-relatively and checked
    // against device/inode and change metadata by GameProjectReader.
    private var fingerprintCache: [UUID: [GameRelativePath: GameFileFingerprint]] = [:]
    private let rootIdentities: [UUID: RootIdentity]

    private struct RootIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        init(_ info: stat) {
            device = UInt64(truncatingIfNeeded: info.st_dev)
            inode = UInt64(truncatingIfNeeded: info.st_ino)
        }
    }

    private struct Stamp: Codable, Equatable {
        let digest: String
        let inode: UInt64
        let modified: Double
        let mode: Int
    }
    private struct Item: Codable {
        let path: String
        let before: Stamp?
        let afterDigest: String?
        let backup: String?
        var installed: Stamp?
        var applied: Bool
    }
    private struct Journal: Codable {
        let projectID: UUID
        let intendedRevision: String
        let root: String
        let workspaceID: UUID
        var items: [Item]
        var addedDirectories: [String]
        var removedDirectories: [String]
    }
    private enum JournalChange: Codable {
        case file(index: Int, installed: Stamp?)
        case addedDirectory(String)
        case removedDirectory(String)
    }

    public init(targets: [ExistingGameWorkspaceTarget], repositoryDirectory: URL) throws {
        guard repositoryDirectory.isFileURL,
              Set(targets.map { $0.binding.projectID }).count == targets.count else {
            throw GameProjectError.invalidContext
        }
        let store = repositoryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        var identities: [UUID: RootIdentity] = [:]
        for target in targets {
            let a = store.pathComponents, b = target.binding.rootURL.pathComponents
            guard !a.starts(with: b), !b.starts(with: a) else { throw GameProjectError.invalidContext }
            var info = stat()
            guard lstat(target.binding.rootURL.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR else { throw GameProjectError.rootUnavailable }
            identities[target.binding.projectID] = RootIdentity(info)
        }
        self.targets = Dictionary(uniqueKeysWithValues: targets.map { ($0.binding.projectID, $0) })
        self.repositoryDirectory = store
        self.rootIdentities = identities
    }

    public func snapshot(projectID: UUID, owner: GameProjectOwner,
                         limits: GameRepositoryLimits) throws -> GameWorkingTreeSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard !activeTransactions.contains(projectID) else { throw GameProjectError.invalidContext }
        let target = try target(projectID, owner)
        try recover(target, limits: limits)
        return try capture(target, limits: limits, allowCache: true)
    }

    public func verifiedSnapshot(projectID: UUID, owner: GameProjectOwner,
                                 limits: GameRepositoryLimits) throws -> GameWorkingTreeSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard !activeTransactions.contains(projectID) else { throw GameProjectError.invalidContext }
        let target = try target(projectID, owner)
        try recover(target, limits: limits)
        return try capture(target, limits: limits)
    }

    /// Only the full-project import path calls this policy. Its complete
    /// original becomes an immutable parent revision before a live import is
    /// published. Ordinary game/AI writes still reject administrative paths.
    public func importedTree(_ project: GameStoredProject, limits: GameRepositoryLimits) throws -> GameWorkingTreeImportTree {
        lock.lock(); defer { lock.unlock() }
        guard !activeTransactions.contains(project.projectID) else { throw GameProjectError.invalidContext }
        _ = try target(project.projectID, project.owner)
        func administrative(_ path: GameRelativePath) -> Bool {
            path.value.split(separator: "/").contains { vcsNames.contains($0.lowercased()) }
        }
        return .init(directories: project.directories.filter { !administrative($0) },
                     files: project.files.filter { !administrative($0.path) })
    }

    public func read(_ file: GameProjectFile, snapshot: GameWorkingTreeSnapshot,
                     limits: GameRepositoryLimits) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard !activeTransactions.contains(snapshot.binding.projectID) else { throw GameProjectError.invalidContext }
        let target = try target(snapshot.binding.projectID, snapshot.binding.owner)
        guard target.binding == snapshot.binding,
              try target.revisions.revisionID() == snapshot.revision else { throw GameProjectError.invalidContext }
        let service = scoped(target, limits)
        _ = try service.guardResolver.resolve(file.path.value)
        let inMemoryLimit = min(limits.maximumFileBytes, 64 * 1_024 * 1_024)
        guard file.bytes <= inMemoryLimit else { throw GameProjectError.limitExceeded(file.path.value) }
        let reader = try GameProjectReader(rootURL: target.binding.rootURL, maximumFileBytes: inMemoryLimit)
        guard let data = try reader.read(file.path), data.count == file.bytes,
              GameDigest.sha256(data) == file.sha256,
              try reader.isExecutable(file.path) == file.executable else {
            throw GameProjectError.conflict(expected: file.sha256, actual: "file changed")
        }
        return data
    }

    /// Review is explicit and does not overwrite a newer external edit. The
    /// pending journal/original bytes remain available to the host recovery UI.
    public func reviewRecovery(projectID: UUID, owner: GameProjectOwner,
                               limits: GameRepositoryLimits) throws -> GameWorkingTreeRecoveryReview {
        lock.lock(); defer { lock.unlock() }
        guard !activeTransactions.contains(projectID) else { throw GameProjectError.invalidContext }
        let target = try target(projectID, owner)
        let directory = recoveryDirectory(projectID)
        let journal = try loadJournal(at: directory, limits: limits)
        guard journal.projectID == projectID, journal.root.hasPrefix("/"),
              GameSpaceRootIdentity.persistedPath(journal.root, owner: target.binding.owner)
                == GameSpaceRootIdentity.persistedPath(target.binding.rootURL.path, owner: target.binding.owner),
              journal.workspaceID == target.binding.workspaceID else { throw GameProjectError.ownershipMismatch }
        let snapshot = try capture(target, limits: limits)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let id = GameDigest.sha256((try encoder.encode(journal)) + Data(snapshot.revision.utf8) + (try JSONEncoder().encode(snapshot.files))
            + (try JSONEncoder().encode(snapshot.directories)))
        return .init(id: id, binding: target.binding, paths: journal.items.map(\.path),
                     retainedOriginals: directory, snapshot: snapshot)
    }

    /// A reviewed "keep current files" resolves the block without deleting
    /// original recovery bytes. Another change after review requires re-review.
    public func keepCurrentFiles(_ review: GameWorkingTreeRecoveryReview,
                                 limits: GameRepositoryLimits) throws {
        lock.lock(); defer { lock.unlock() }
        let current = try reviewRecovery(projectID: review.binding.projectID, owner: review.binding.owner, limits: limits)
        guard current.id == review.id, current.snapshot == review.snapshot, current.binding == review.binding else {
            throw GameProjectError.conflict(expected: review.id, actual: current.id)
        }
        let resolved = repositoryDirectory.appendingPathComponent(review.binding.projectID.uuidString.lowercased()
            + "/ResolvedRecovery/" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: resolved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: current.retainedOriginals, to: resolved)
        targets[review.binding.projectID]?.revisions.notifySavedFilesChanged()
    }

    public func transact(project: GameStoredProject, previous: GameStoredProject?,
                         limits: GameRepositoryLimits,
                         readObject: (GameProjectFile) throws -> Data,
                         objectURL: (GameProjectFile) throws -> URL,
                         publishMetadata: (String?) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard !activeTransactions.contains(project.projectID) else { throw GameProjectError.invalidContext }
        let target = try target(project.projectID, project.owner)
        try recover(target, limits: limits)
        activeTransactions.insert(project.projectID)
        defer { activeTransactions.remove(project.projectID) }
        let before = try capture(target, limits: limits)
        if let previous {
            guard before.files == previous.files, before.directories == previous.directories,
                  before.revision == previous.workspaceRevision else {
                throw GameProjectError.conflict(expected: previous.revision, actual: before.revision)
            }
        } else if !before.files.isEmpty || !before.directories.isEmpty {
            throw GameProjectError.importDestinationNotEmpty
        }
        let service = scoped(target, limits)
        let old = Dictionary(uniqueKeysWithValues: before.files.map { ($0.path.value, $0) })
        let new = Dictionary(uniqueKeysWithValues: project.files.map { ($0.path.value, $0) })
        let changed = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }.sorted()
        // Existing-file replacement and rollback still use Data-based APIs.
        // Refuse those operations before mutation when their payload is large;
        // importing a new file remains streaming and has no fixed byte cap.
        let inMemoryLimit = min(limits.maximumFileBytes, 64 * 1_024 * 1_024)
        for path in changed where old[path] != nil {
            guard (old[path]?.bytes ?? 0) <= inMemoryLimit,
                  (new[path]?.bytes ?? 0) <= inMemoryLimit else { throw GameProjectError.limitExceeded(path) }
        }
        // Administrative Git data may exist in an imported original archive,
        // but a game save must never adopt it over the live IDE repository.
        for path in project.files.map({ $0.path.value }) + project.directories.map({ $0.value }) {
            try rejectVCS(path)
        }
        for path in changed {
            let url = try service.guardResolver.resolve(path)
            try service.mutationGuard?(url)
        }
        let directory = recoveryDirectory(project.projectID)
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw recoveryError(directory, changed) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var journal = Journal(projectID: project.projectID, intendedRevision: project.revision,
            root: target.binding.rootURL.path, workspaceID: target.binding.workspaceID, items: [],
            addedDirectories: [], removedDirectories: [])
        let originalDirectories = Set(before.directories), proposedDirectories = Set(project.directories)
        let desiredAdded = proposedDirectories.subtracting(originalDirectories).map(\.value)
        let desiredRemoved = originalDirectories.subtracting(proposedDirectories).map(\.value)
        let reader = try GameProjectReader(rootURL: target.binding.rootURL, maximumFileBytes: limits.maximumFileBytes)
        do {
            try save(journal, at: directory)
            for (index, path) in changed.enumerated() {
                try Task.checkCancellation()
                let stamp = old[path] == nil ? nil : try stamp(path, target, limits: limits)
                let backup = stamp == nil ? nil : "old-" + String(index)
                if let backup {
                    guard let data = try reader.read(GameRelativePath(path)) else { throw GameProjectError.corruptStorage }
                    try GameWorkingTreeJournalFiles.write(data, to: directory.appendingPathComponent(backup))
                }
                journal.items.append(.init(path: path, before: stamp, afterDigest: new[path]?.sha256,
                    backup: backup, installed: nil, applied: false))
            }
            try save(journal, at: directory)
            guard before == (try capture(target, limits: limits)) else { throw GameProjectError.invalidContext }
            for path in desiredAdded.sorted(by: { $0.count < $1.count }) {
                try Task.checkCancellation()
                let url = try service.guardResolver.resolve(path)
                try service.mutationGuard?(url)
                if !FileManager.default.fileExists(atPath: url.path) {
                    try service.createDirectory(path)
                    journal.addedDirectories.append(path)
                    try saveChange(.addedDirectory(path), named: "add-\(journal.addedDirectories.count)", at: directory)
                }
            }
            for index in journal.items.indices {
                try Task.checkCancellation()
                let path = journal.items[index].path
                guard try stamp(path, target, limits: limits) == journal.items[index].before else {
                    throw GameProjectError.conflict(expected: "captured file", actual: "file changed")
                }
                if let file = new[path] {
                    if old[path] == nil, file.bytes > 0 {
                        let outcome = try service.importUserFile(from: objectURL(file), to: path, expectedSHA256: file.sha256)
                        guard outcome.bytesWritten == file.bytes, outcome.sha256 == file.sha256 else { throw GameProjectError.corruptStorage }
                    } else {
                        let data = try readObject(file)
                        guard data.count == file.bytes, GameDigest.sha256(data) == file.sha256 else { throw GameProjectError.corruptStorage }
                        try service.createBinaryFile(path, data: data, overwrite: old[path] != nil)
                    }
                    journal.items[index].applied = true
                    journal.items[index].installed = try stamp(path, target, limits: limits)
                    let originalMode = journal.items[index].before?.mode ?? 0o600
                    let mode = file.executable ? originalMode | 0o100 : originalMode & ~0o111
                    if journal.items[index].installed?.mode != mode {
                        try saveChange(.file(index: index, installed: journal.items[index].installed), named: "file-\(index)", at: directory)
                        let url = try service.guardResolver.resolve(path)
                        try service.mutationGuard?(url)
                        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
                        journal.items[index].installed = try stamp(path, target, limits: limits)
                    }
                } else {
                    try service.delete(path)
                    journal.items[index].applied = true
                }
                try saveChange(.file(index: index, installed: journal.items[index].installed), named: "file-\(index)", at: directory)
            }
            for path in desiredRemoved.sorted(by: { $0.count > $1.count }) {
                let url = try service.guardResolver.resolve(path)
                if FileManager.default.fileExists(atPath: url.path) {
                    try service.mutationGuard?(url)
                    try service.delete(path, recursive: false)
                    journal.removedDirectories.append(path)
                    try saveChange(.removedDirectory(path), named: "remove-\(journal.removedDirectories.count)", at: directory)
                }
            }
            let after = try capture(target, limits: limits)
            guard after.files == project.files, after.directories == project.directories else {
                throw GameProjectError.conflict(expected: "proposed tree", actual: "file tree changed")
            }
            try Task.checkCancellation()
            target.revisions.notifySavedFilesChanged()
            try publishMetadata(target.revisions.revisionID())
        } catch {
            let original = error
            do { try rollback(journal, target, limits: limits, directory: directory) }
            catch { throw error }
            throw original
        }
        // The live files and HEAD now agree. Cleanup is optional; a restart
        // recognizes the intended revision and verifies the installed bytes.
        try? FileManager.default.removeItem(at: directory)
    }

    private func capture(_ target: ExistingGameWorkspaceTarget, limits: GameRepositoryLimits,
                         allowCache: Bool = false) throws -> GameWorkingTreeSnapshot {
        let revision = try target.revisions.revisionID()
        try verifyRoot(target)
        let reader = try GameProjectReader(rootURL: target.binding.rootURL, maximumFileBytes: limits.maximumFileBytes)
        let entries = try reader.tree(maximumEntries: limits.maximumEntries, excludingNames: vcsNames)
        let service = scoped(target, limits)
        var total = 0, files: [GameProjectFile] = []
        // Only app-owned Space games use hints. Ordinary workspace roots can
        // be externally provided filesystems with unreliable change metadata.
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath().pathComponents
        let appOwned: Bool
        if case .space = target.binding.owner {
            appOwned = target.binding.rootURL.pathComponents.starts(with: home)
        } else { appOwned = false }
        let cached = allowCache && appOwned ? (fingerprintCache[target.binding.projectID] ?? [:]) : [:]
        var nextCache: [GameRelativePath: GameFileFingerprint] = [:]
        for entry in entries {
            _ = try service.guardResolver.resolve(entry.path.value)
            if entry.directory { continue }
            guard let data = try reader.fingerprintWithIdentity(entry.path, cached: cached[entry.path]),
                  total <= limits.maximumProjectBytes - data.bytes else {
                throw GameProjectError.limitExceeded("projectBytes")
            }
            total += data.bytes
            nextCache[entry.path] = data
            files.append(.init(path: entry.path, sha256: data.sha256, bytes: data.bytes,
                               executable: try reader.isExecutable(entry.path)))
        }
        guard revision == (try target.revisions.revisionID()) else { throw GameProjectError.invalidContext }
        try verifyRoot(target)
        let snapshot = try GameWorkingTreeSnapshot(binding: target.binding, revision: revision,
            directories: entries.filter(\.directory).map(\.path), files: files)
        fingerprintCache[target.binding.projectID] = nextCache
        return snapshot
    }

    private func verifyRoot(_ target: ExistingGameWorkspaceTarget) throws {
        var info = stat()
        guard lstat(target.binding.rootURL.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              rootIdentities[target.binding.projectID] == RootIdentity(info) else {
            throw GameProjectError.rootUnavailable
        }
    }

    private func target(_ id: UUID, _ owner: GameProjectOwner) throws -> ExistingGameWorkspaceTarget {
        guard let target = targets[id], target.binding.owner == owner else { throw GameProjectError.ownershipMismatch }
        _ = try target.revisions.checkpoint()
        return target
    }
    private func scoped(_ target: ExistingGameWorkspaceTarget, _ limits: GameRepositoryLimits) -> WorkspaceFileService {
        WorkspaceFileService(guard: target.service.guardResolver.withReadLimit(limits.maximumFileBytes)
            .withWriteLimit(limits.maximumFileBytes), mutationGuard: target.service.mutationGuard)
    }
    private func rejectVCS(_ path: String) throws {
        guard !path.split(separator: "/").contains(where: { vcsNames.contains($0.lowercased()) }) else {
            throw GameProjectError.unsafePath(path)
        }
    }
    private func stamp(_ path: String, _ target: ExistingGameWorkspaceTarget,
                       limits: GameRepositoryLimits) throws -> Stamp? {
        let url = try scoped(target, limits).guardResolver.resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let reader = try GameProjectReader(rootURL: target.binding.rootURL, maximumFileBytes: limits.maximumFileBytes)
        guard let data = try reader.fingerprint(GameRelativePath(path), honorCancellation: false) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return .init(digest: data.sha256, inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            mode: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600)
    }
    private func recoveryDirectory(_ id: UUID) -> URL {
        repositoryDirectory.appendingPathComponent(id.uuidString.lowercased() + "/LiveRecovery")
    }
    private func save(_ journal: Journal, at directory: URL) throws {
        try GameWorkingTreeJournalFiles.write(JSONEncoder().encode(journal), to: directory.appendingPathComponent("pending.json"))
    }
    // The complete plan and backups are durable before any live change. Keep
    // each subsequent checkpoint independently atomic so imports scale with
    // the number of files without rewriting the entire plan for every file.
    private func saveChange(_ change: JournalChange, named name: String, at directory: URL) throws {
        let url = directory.appendingPathComponent("change-" + name + ".json")
        try GameWorkingTreeJournalFiles.write(JSONEncoder().encode(change), to: url)
    }

    private func loadJournal(at directory: URL, limits: GameRepositoryLimits) throws -> Journal {
        let data = try GameWorkingTreeJournalFiles.read(directory.appendingPathComponent("pending.json"), maximum: 32 * 1_024 * 1_024)
        let decoder = JSONDecoder()
        var journal = try decoder.decode(Journal.self, from: data)
        let changes = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("change-") && $0.hasSuffix(".json") }.sorted()
        guard journal.items.count <= limits.maximumEntries,
              changes.count <= limits.maximumEntries * 3 else { throw GameProjectError.corruptStorage }
        for name in changes {
            let bytes = try GameWorkingTreeJournalFiles.read(directory.appendingPathComponent(name), maximum: 32 * 1_024)
            switch try decoder.decode(JournalChange.self, from: bytes) {
            case .file(let index, let installed):
                guard journal.items.indices.contains(index), name == "change-file-\(index).json" else {
                    throw GameProjectError.corruptStorage
                }
                journal.items[index].installed = installed
                journal.items[index].applied = true
            case .addedDirectory(let path):
                journal.addedDirectories.append(path)
            case .removedDirectory(let path):
                journal.removedDirectories.append(path)
            }
        }
        return journal
    }
    private func recoveryError(_ directory: URL, _ conflicts: [String]) -> GameWorkingTreeRecoveryRequired {
        .init(recoveryDirectory: directory, conflictingPaths: conflicts)
    }

    private func rollback(_ journal: Journal, _ target: ExistingGameWorkspaceTarget,
                          limits: GameRepositoryLimits, directory: URL) throws {
        let service = scoped(target, limits)
        var conflicts: [String] = []
        for item in journal.items.reversed() {
            do {
                let current = try stamp(item.path, target, limits: limits)
                // Already original (including an unapplied entry): no write.
                if current?.digest == item.before?.digest, current?.mode == item.before?.mode { continue }
                guard item.applied, current == item.installed else { conflicts.append(item.path); continue }
                if let backup = item.backup, let before = item.before {
                    let bytes = try GameWorkingTreeJournalFiles.read(directory.appendingPathComponent(backup), maximum: min(limits.maximumFileBytes, 64 * 1_024 * 1_024))
                    guard GameDigest.sha256(bytes) == before.digest else { throw GameProjectError.corruptStorage }
                    try service.createBinaryFile(item.path, data: bytes, overwrite: current != nil)
                    let url = try service.guardResolver.resolve(item.path)
                    try service.mutationGuard?(url)
                    try FileManager.default.setAttributes([.posixPermissions: before.mode], ofItemAtPath: url.path)
                } else if current != nil { try service.delete(item.path) }
            } catch { conflicts.append(item.path) }
        }
        for path in journal.removedDirectories.sorted(by: { $0.count < $1.count }) {
            do {
                let url = try service.guardResolver.resolve(path)
                if !FileManager.default.fileExists(atPath: url.path) {
                    try service.mutationGuard?(url); try service.createDirectory(path)
                }
            } catch { conflicts.append(path) }
        }
        for path in journal.addedDirectories.sorted(by: { $0.count > $1.count }) {
            do {
                let url = try service.guardResolver.resolve(path)
                if FileManager.default.fileExists(atPath: url.path),
                   try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty {
                    try service.mutationGuard?(url); try service.delete(path)
                }
            } catch { conflicts.append(path) }
        }
        target.revisions.notifySavedFilesChanged()
        guard conflicts.isEmpty else { throw recoveryError(directory, conflicts) }
        try FileManager.default.removeItem(at: directory)
    }

    private func recover(_ target: ExistingGameWorkspaceTarget, limits: GameRepositoryLimits) throws {
        let directory = recoveryDirectory(target.binding.projectID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let journal = try loadJournal(at: directory, limits: limits)
        guard journal.projectID == target.binding.projectID, journal.root.hasPrefix("/"),
              GameSpaceRootIdentity.persistedPath(journal.root, owner: target.binding.owner)
                == GameSpaceRootIdentity.persistedPath(target.binding.rootURL.path, owner: target.binding.owner),
              journal.workspaceID == target.binding.workspaceID,
              journal.items.count <= limits.maximumEntries else { throw GameProjectError.corruptStorage }
        guard UUID(uuidString: journal.intendedRevision) != nil,
              journal.addedDirectories.count + journal.removedDirectories.count <= limits.maximumEntries * 2 else {
            throw GameProjectError.corruptStorage
        }
        for path in journal.addedDirectories + journal.removedDirectories {
            _ = try GameRelativePath(path); try rejectVCS(path)
        }
        for item in journal.items {
            _ = try GameRelativePath(item.path); try rejectVCS(item.path)
            if let backup = item.backup {
                guard backup.hasPrefix("old-"), !backup.contains("/"), !backup.contains("\\") else { throw GameProjectError.corruptStorage }
            }
        }
        let head = repositoryDirectory.appendingPathComponent(target.binding.projectID.uuidString.lowercased() + "/HEAD.json")
        if let bytes = try? GameWorkingTreeJournalFiles.read(head, maximum: 4_096),
           let object = try JSONSerialization.jsonObject(with: bytes) as? [String: String],
           object["revision"] == journal.intendedRevision {
            var conflicts: [String] = []
            for item in journal.items {
                if try stamp(item.path, target, limits: limits)?.digest != item.afterDigest { conflicts.append(item.path) }
            }
            guard conflicts.isEmpty else { throw recoveryError(directory, conflicts) }
            try? FileManager.default.removeItem(at: directory)
        } else { try rollback(journal, target, limits: limits, directory: directory) }
    }
}
