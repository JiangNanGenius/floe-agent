// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import Darwin

/// A host-produced CAS snapshot, never a tool argument or an authorization.
public struct BiologyPermanentDeletionPlan: Codable, Hashable, Sendable {
    public let projectID: UUID
    public let transactionID: UUID
    public let trashID: String
    public let revision: UInt64
    public let sourceIdentity: String
    public let identity: String
    public let completed: Bool
    fileprivate let source: BiologyPurgeSource
    fileprivate let progress: [BiologyPurgeProgress]
}
public struct BiologyPermanentDeletionReceipt: Sendable {
    public let projectID: UUID
    public let transactionID: UUID
    public let sourceIdentity: String
}
public enum BiologyPermanentDeletionCheckpoint: Sendable {
    case prepared, staged, beforeIrreversible, removedNode, beforeCompletion
}
fileprivate struct BiologyPurgeTarget: Codable, Hashable, Sendable {
    enum Root: String, Codable, Sendable { case projects, files }
    let root: Root
    let path: String
    let stage: String
    let directory: Bool
    let resourceIdentity: String
    let treeIdentity: String
}
fileprivate struct BiologyPurgeSource: Codable, Hashable, Sendable {
    let projectID: UUID
    let transactionID: UUID
    let trashID: String
    let revision: UInt64
    let headDigest: String
    let projectRootIdentity: String
    let filesRootIdentity: String?
    let targets: [BiologyPurgeTarget]
}
fileprivate struct BiologyPurgeProgress: Codable, Hashable, Sendable {
    enum Location: String, Codable, Sendable { case original, staged, removed }
    let location: Location
    let treeIdentity: String
}
fileprivate struct BiologyPurgeJournal: Codable, Sendable {
    enum Phase: String, Codable, Sendable { case prepared, removing, complete }
    var version = 1
    let source: BiologyPurgeSource
    var phase: Phase
}

extension BiologyProjectStore {
    /// Trusted native use only. Both the saved deleted revision and every
    /// project-owned native file namespace are captured before confirmation.
    public func permanentDeletionPlan(projectID: UUID, trashID: String, transactionID: UUID) throws -> BiologyPermanentDeletionPlan {
        guard let ownedFilesRoot else { throw BiologyError.unavailable("Native original-file storage is not configured for permanent deletion.") }
        return try locked {
            if let journal = try BiologyPurgeIO.journal(root: root, id: projectID) {
                guard journal.source.transactionID == transactionID, journal.source.trashID == trashID else { throw BiologyError.invalid("The permanent-deletion transaction changed.") }
                return try BiologyPurgeIO.plan(journal, projects: root, files: ownedFilesRoot)
            }
            let id = projectID.uuidString.lowercased()
            let path: String
            let project: BiologyProject
            if trashID == id {
                path = id; project = try current(projectID)
                guard project.deletedAt != nil else { throw BiologyError.invalid("Only an already deleted original can be permanently removed.") }
            } else {
                guard trashID.count == 73, trashID.hasPrefix(id + "-"), UUID(uuidString: String(trashID.suffix(36))) != nil,
                      !fm.fileExists(atPath: root.appendingPathComponent(id).path) else { throw BiologyError.invalid("The deleted original identity changed.") }
                path = "Trash/" + trashID
                try BiologyPurgeIO.ensureProjectPath(root: root, path: path)
                let directory = root.appendingPathComponent(path)
                let head = try JSONDecoder().decode(PurgeHead.self, from: read(directory.appendingPathComponent("HEAD.json"), maximum: 4_096))
                let data = try read(directory.appendingPathComponent("revisions/\(head.revision).json"))
                guard Self.digest(data) == head.digest else { throw BiologyError.corrupt("Deleted project integrity verification failed.") }
                project = try JSONDecoder().decode(BiologyProject.self, from: data)
                guard project.id == projectID, project.revision == head.revision else { throw BiologyError.corrupt("Deleted project revision changed.") }
                try Self.validate(project)
            }
            guard !project.runs.contains(where: \.isActive) else { throw BiologyError.invalid("Stop active or unconfirmed calculations before permanent deletion.") }
            let head = try read(root.appendingPathComponent(path).appendingPathComponent("HEAD.json"), maximum: 4_096)
            let source = try BiologyPurgeIO.source(project: project, trashID: trashID, transactionID: transactionID,
                projectPath: path, headDigest: Self.digest(head), projects: root, files: ownedFilesRoot)
            return try BiologyPurgeIO.plan(.init(source: source, phase: .prepared), projects: root, files: ownedFilesRoot, unclaimed: true)
        }
    }
    private struct PurgeHead: Decodable { let revision: UInt64; let digest: String }

    /// No UUID/JSON boolean grants this operation permission. The App holds
    /// its existing Library usage/folder barrier and native-file fence first.
    public func permanentlyDelete(_ expected: BiologyPermanentDeletionPlan,
        checkpoint: (@Sendable (BiologyPermanentDeletionCheckpoint) throws -> Void)? = nil) throws -> BiologyPermanentDeletionReceipt {
        guard let ownedFilesRoot else { throw BiologyError.unavailable("Native original-file storage is not configured.") }
        return try locked {
            let currentPlan = try permanentDeletionPlanLocked(expected, files: ownedFilesRoot)
            guard currentPlan == expected else { throw BiologyError.invalid("The confirmed native original changed. Refresh and select it again.") }
            return try BiologyPurgeIO.remove(expected, projects: root, files: ownedFilesRoot, checkpoint: checkpoint)
        }
    }
    // Reconstruct without recursively taking this store's flock.
    private func permanentDeletionPlanLocked(_ expected: BiologyPermanentDeletionPlan, files: URL) throws -> BiologyPermanentDeletionPlan {
        try BiologyPurgeIO.validate(expected.source)
        if let journal = try BiologyPurgeIO.journal(root: root, id: expected.projectID) {
            guard journal.source.transactionID == expected.transactionID, journal.source == expected.source else { throw BiologyError.invalid("Native purge source changed.") }
            return try BiologyPurgeIO.plan(journal, projects: root, files: files)
        }
        // Before claiming, independently verify the immutable HEAD and deleted
        // native revision, not just a self-described tree in the snapshot.
        try BiologyPurgeIO.ensureProjectPath(root: root, path: expected.source.targets[0].path)
        let path = root.appendingPathComponent(expected.source.targets[0].path)
        let headBytes = try read(path.appendingPathComponent("HEAD.json"), maximum: 4_096)
        let head = try JSONDecoder().decode(PurgeHead.self, from: headBytes)
        let data = try read(path.appendingPathComponent("revisions/\(head.revision).json"))
        let project = try JSONDecoder().decode(BiologyProject.self, from: data)
        guard Self.digest(data) == head.digest, Self.digest(headBytes) == expected.source.headDigest,
              project.id == expected.projectID, project.revision == expected.revision,
              expected.trashID != expected.projectID.uuidString.lowercased() || project.deletedAt != nil,
              !project.runs.contains(where: \.isActive) else { throw BiologyError.invalid("Native revision or worker state changed.") }
        try Self.validate(project)
        return try BiologyPurgeIO.plan(.init(source: expected.source, phase: .prepared), projects: root, files: files, unclaimed: true)
    }
    /// A durable marker blocks restore/edit/ID reuse while either side needs
    /// recovery. A completed marker is intentionally retained without content.
    public func hasPermanentDeletionRecord(projectID: UUID, transactionID: UUID) throws -> Bool {
        try locked {
            guard let value = try BiologyPurgeIO.journal(root: root, id: projectID) else { return false }
            guard value.source.transactionID == transactionID else { throw BiologyError.invalid("Native purge transaction changed.") }
            return true
        }
    }
}

/// Only exact canonical native roots and project-derived relative targets are
/// used. No model-supplied path, symlink traversal or host executor is exposed.
enum BiologyPurgeIO {
    private static let budget = 200_000
    private static let markerDirectory = ".permanent-deletion"
    private static func fail() throws -> Never { throw BiologyError.corrupt("Native permanent-deletion storage changed; remaining data is retained for recovery.") }
    private static func id(_ value: stat) -> String { "\(value.st_dev):\(value.st_ino):\(value.st_birthtimespec.tv_sec):\(value.st_birthtimespec.tv_nsec)" }
    private static func information(_ fd: Int32) throws -> stat { var value = stat(); guard fstat(fd, &value) == 0 else { try fail() }; return value }
    private static func root(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.standardizedFileURL.path == url.path,
              url.resolvingSymlinksInPath().standardizedFileURL.path == url.path else { try fail() }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { try fail() }; return fd
    }
    private static func optionalRoot(_ url: URL) throws -> Int32? {
        var value = stat()
        if lstat(url.path, &value) != 0 { guard errno == ENOENT else { try fail() }; return nil }
        return try root(url)
    }
    private static func names(_ fd: Int32) throws -> [String] {
        let copy = dup(fd); guard copy >= 0 else { try fail() }
        guard let stream = fdopendir(copy) else { close(copy); try fail() }; defer { closedir(stream) }
        rewinddir(stream); var result: [String] = []
        while true {
            errno = 0; guard let entry = readdir(stream) else { guard errno == 0 else { try fail() }; break }
            let name: String? = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingCString: $0) }
            }
            guard let name else { try fail() }; if name != "." && name != ".." { result.append(name) }
            guard result.count <= budget else { throw BiologyError.invalid("Native original has too many file entries.") }
        }
        return result.sorted()
    }
    private static func parent(_ root: Int32, _ path: String) throws -> (Int32, String) {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !pieces.isEmpty, pieces.count <= 64, pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") && !$0.contains("\\") && !$0.contains(":") }) else { try fail() }
        var current = dup(root); guard current >= 0 else { try fail() }
        for part in pieces.dropLast() {
            let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); close(current)
            guard next >= 0 else { try fail() }; current = next
        }
        return (current, pieces.last!)
    }
    private static func statAt(_ root: Int32, _ path: String) throws -> stat? {
        let (parent, name) = try parent(root, path); defer { close(parent) }; var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return info }
        guard errno == ENOENT else { try fail() }; return nil
    }
    private static func directoryAt(_ root: Int32, _ path: String) throws -> Int32 {
        let (parent, name) = try parent(root, path); defer { close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { try fail() }; return fd
    }
    private static func digest(_ data: Data) -> String { BiologyProjectStore.digest(data) }
    private static func fingerprint(_ root: Int32, _ path: String, directory: Bool, checkCancellation: Bool = true) throws -> (String, String) {
        let (parent, name) = try parent(root, path); defer { close(parent) }
        var info = stat(); guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { try fail() }
        guard (info.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG) else { try fail() }
        let identity = id(info); var hasher = SHA256(), count = 0
        func visit(_ directory: Int32, prefix: String, depth: Int) throws {
            guard depth <= 256 else { try fail() }
            let own = try information(directory)
            hasher.update(data: Data("D\0\(prefix)\0\(id(own))\0\(own.st_mode)\0\(own.st_mtimespec.tv_sec):\(own.st_mtimespec.tv_nsec)\n".utf8))
            for childName in try names(directory) {
                if checkCancellation { try Task.checkCancellation() }; count += 1; guard count <= budget else { try fail() }
                var child = stat(); guard fstatat(directory, childName, &child, AT_SYMLINK_NOFOLLOW) == 0 else { try fail() }
                let relative = prefix + "/" + childName
                if child.st_mode & S_IFMT == S_IFDIR {
                    let fd = openat(directory, childName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { try fail() }; defer { close(fd) }
                    guard id(try information(fd)) == id(child) else { try fail() }; try visit(fd, prefix: relative, depth: depth + 1)
                } else {
                    hasher.update(data: Data("F\0\(relative)\0\(id(child))\0\(child.st_mode)\0\(child.st_size)\0\(child.st_mtimespec.tv_sec):\(child.st_mtimespec.tv_nsec)\0\(child.st_ctimespec.tv_sec):\(child.st_ctimespec.tv_nsec)\n".utf8))
                }
            }
        }
        if directory { let fd = try directoryAt(root, path); defer { close(fd) }; guard id(try information(fd)) == identity else { try fail() }; try visit(fd, prefix: "", depth: 0) }
        else { hasher.update(data: Data("F\0\(identity)\0\(info.st_mode)\0\(info.st_size)\0\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)\n".utf8)) }
        return (identity, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
    private static func ownedNamespaces(_ fd: Int32?, project: UUID) throws -> [String] {
        guard let fd else { return [] }; var result: [String] = []
        for name in try names(fd) {
            guard name.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { try fail() }
            let namespace = try directoryAt(fd, name); defer { close(namespace) }
            if let info = try statAt(namespace, project.uuidString.lowercased()) {
                guard info.st_mode & S_IFMT == S_IFDIR else { try fail() }; result.append(name)
            }
        }
        guard result.count <= 1_024 else { try fail() }; return result
    }
    fileprivate static func source(project: BiologyProject, trashID: String, transactionID: UUID, projectPath: String,
        headDigest: String, projects: URL, files: URL) throws -> BiologyPurgeSource {
        let p = try root(projects); defer { close(p) }; let f = try optionalRoot(files); defer { if let f { close(f) } }
        let stage = ".FloeBiologyPurge-" + transactionID.uuidString.lowercased() + "-" + project.id.uuidString.lowercased()
        func target(_ slot: BiologyPurgeTarget.Root, _ fd: Int32, _ path: String, directory: Bool) throws -> BiologyPurgeTarget {
            let result = try fingerprint(fd, path, directory: directory)
            let parts = path.split(separator: "/").dropLast().map(String.init)
            return .init(root: slot, path: path, stage: (parts + [stage + (directory ? "" : "-index")]).joined(separator: "/"),
                directory: directory, resourceIdentity: result.0, treeIdentity: result.1)
        }
        var targets = [try target(.projects, p, projectPath, directory: true)]
        if trashID == project.id.uuidString.lowercased(), let info = try statAt(p, "Trash/" + trashID + ".json") {
            guard info.st_mode & S_IFMT == S_IFREG else { try fail() }
            targets.append(try target(.projects, p, "Trash/" + trashID + ".json", directory: false))
        }
        for namespace in try ownedNamespaces(f, project: project.id) {
            targets.append(try target(.files, f!, namespace + "/" + project.id.uuidString.lowercased(), directory: true))
        }
        return .init(projectID: project.id, transactionID: transactionID, trashID: trashID, revision: project.revision,
            headDigest: headDigest, projectRootIdentity: id(try information(p)), filesRootIdentity: try f.map { id(try information($0)) }, targets: targets)
    }
    fileprivate static func validate(_ source: BiologyPurgeSource) throws {
        let id = source.projectID.uuidString.lowercased()
        let modern = source.trashID == id
        guard modern || (source.trashID.count == 73 && source.trashID.hasPrefix(id + "-") && UUID(uuidString: String(source.trashID.suffix(36))) != nil),
              source.revision > 0, source.headDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              !source.targets.isEmpty, source.targets.count <= 1_026 else { try fail() }
        let first = source.targets[0]
        guard first.root == .projects, first.directory, first.path == (modern ? id : "Trash/" + source.trashID) else { try fail() }
        let stage = ".FloeBiologyPurge-" + source.transactionID.uuidString.lowercased() + "-" + id
        var paths = Set<String>()
        for (index, target) in source.targets.enumerated() {
            guard paths.insert(target.root.rawValue + ":" + target.path).inserted,
                  target.stage == (target.path.split(separator: "/").dropLast().map(String.init) + [stage + (target.directory ? "" : "-index")]).joined(separator: "/") else { try fail() }
            if index == 0 { continue }
            if target.root == .projects {
                guard modern, !target.directory, target.path == "Trash/" + id + ".json" else { try fail() }
            } else {
                let pieces = target.path.split(separator: "/", omittingEmptySubsequences: false)
                guard target.directory, pieces.count == 2, pieces[1] == id,
                      pieces[0].range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { try fail() }
            }
        }
    }
    static func ensureProjectPath(root url: URL, path: String) throws {
        let r = try root(url); defer { close(r) }; let directory = try directoryAt(r, path); close(directory)
    }
    static func isFenced(root: URL, id: UUID) throws -> Bool { try journal(root: root, id: id) != nil }
    static func requireAvailable(root: URL, id: UUID) throws {
        if try isFenced(root: root, id: id) { throw BiologyError.unavailable("This original has a permanent-deletion record. Restore, edit and identity reuse are unavailable.") }
    }
    fileprivate static func journal(root url: URL, id: UUID) throws -> BiologyPurgeJournal? {
        let r = try root(url); defer { close(r) }
        guard let info = try statAt(r, markerDirectory) else { return nil }; guard info.st_mode & S_IFMT == S_IFDIR else { try fail() }
        let dir = try directoryAt(r, markerDirectory); defer { close(dir) }
        let file = openat(dir, id.uuidString.lowercased() + ".json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if file < 0 { guard errno == ENOENT else { try fail() }; return nil }; defer { close(file) }
        let value = try information(file); guard value.st_mode & S_IFMT == S_IFREG, value.st_size > 0, value.st_size <= 262_144 else { try fail() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true { let n = Darwin.read(file, &buffer, buffer.count); if n == 0 { break }; if n < 0 { if errno == EINTR { continue }; try fail() }; data.append(contentsOf: buffer.prefix(n)); guard data.count <= 262_144 else { try fail() } }
        let result = try JSONDecoder().decode(BiologyPurgeJournal.self, from: data)
        guard result.version == 1, result.source.projectID == id else { try fail() }
        try validate(result.source); return result
    }
    private static func save(_ journal: BiologyPurgeJournal, root: Int32) throws {
        if mkdirat(root, markerDirectory, 0o700) != 0, errno != EEXIST { try fail() }
        let directory = try directoryAt(root, markerDirectory); defer { close(directory) }
        let bytes = try BiologyCoding.encode(journal); guard bytes.count <= 262_144 else { try fail() }
        let temp = ".write-" + UUID().uuidString.lowercased(); let file = openat(directory, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { try fail() }; defer { close(file); _ = unlinkat(directory, temp, 0) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count { let n = Darwin.write(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset); if n < 0, errno == EINTR { continue }; guard n > 0 else { try fail() }; offset += n }
        }
        guard fsync(file) == 0, renameat(directory, temp, directory, journal.source.projectID.uuidString.lowercased() + ".json") == 0 else { try fail() }; _ = fsync(directory)
    }
    private static func unclaim(_ project: UUID, root: Int32) throws {
        let directory = try directoryAt(root, markerDirectory); defer { close(directory) }
        guard unlinkat(directory, project.uuidString.lowercased() + ".json", 0) == 0 else { try fail() }; _ = fsync(directory)
    }
    fileprivate static func plan(_ journal: BiologyPurgeJournal, projects: URL, files: URL, unclaimed: Bool = false) throws -> BiologyPermanentDeletionPlan {
        let p = try root(projects); defer { close(p) }; let f = try optionalRoot(files); defer { if let f { close(f) } }
        let source = journal.source
        try validate(source)
        let actualFilesIdentity = try f.map { id(try information($0)) }
        guard id(try information(p)) == source.projectRootIdentity,
              source.filesRootIdentity == nil || actualFilesIdentity == source.filesRootIdentity else { try fail() }
        let expectedNamespaces = Set(source.targets.filter { $0.root == .files }.map { String($0.path.split(separator: "/")[0]) })
        guard Set(try ownedNamespaces(f, project: source.projectID)).isSubset(of: expectedNamespaces) else { try fail() }
        var progress: [BiologyPurgeProgress] = []
        for target in source.targets {
            guard let r = target.root == .projects ? p : f else { try fail() }
            let original = try statAt(r, target.path), staged = try statAt(r, target.stage)
            guard original == nil || staged == nil else { try fail() }
            let path: String
            let location: BiologyPurgeProgress.Location
            if original != nil { guard journal.phase == .prepared else { try fail() }; path = target.path; location = .original }
            else if staged != nil { guard !unclaimed, journal.phase != .complete else { try fail() }; path = target.stage; location = .staged }
            else { guard !unclaimed, journal.phase != .prepared else { try fail() }; progress.append(.init(location: .removed, treeIdentity: "removed")); continue }
            let value = try fingerprint(r, path, directory: target.directory)
            guard value.0 == target.resourceIdentity, journal.phase != .prepared || value.1 == target.treeIdentity else { try fail() }
            progress.append(.init(location: location, treeIdentity: value.1))
        }
        let sourceID = digest(try BiologyCoding.encode(source))
        struct Pin: Encodable { let source: String; let progress: [BiologyPurgeProgress]; let phase: BiologyPurgeJournal.Phase }
        return .init(projectID: source.projectID, transactionID: source.transactionID, trashID: source.trashID, revision: source.revision,
            sourceIdentity: sourceID, identity: digest(try BiologyCoding.encode(Pin(source: sourceID, progress: progress, phase: journal.phase))),
            completed: journal.phase == .complete, source: source, progress: progress)
    }
    private static func rename(_ target: BiologyPurgeTarget, root: Int32, forward: Bool) throws {
        let (parent, original) = try parent(root, target.path); defer { close(parent) }
        let staged = String(target.stage.split(separator: "/").last!)
        guard renameatx_np(parent, forward ? original : staged, parent, forward ? staged : original, UInt32(RENAME_EXCL)) == 0 else { try fail() }; _ = fsync(parent)
    }
    fileprivate static func remove(_ plan: BiologyPermanentDeletionPlan, projects: URL, files: URL,
        checkpoint: (@Sendable (BiologyPermanentDeletionCheckpoint) throws -> Void)?) throws -> BiologyPermanentDeletionReceipt {
        let p = try root(projects); defer { close(p) }; let f = try optionalRoot(files); defer { if let f { close(f) } }
        var journal = try journal(root: projects, id: plan.projectID) ?? .init(source: plan.source, phase: .prepared)
        if journal.phase == .complete { return .init(projectID: plan.projectID, transactionID: plan.transactionID, sourceIdentity: plan.sourceIdentity) }
        if journal.phase == .prepared {
            do {
                try Task.checkCancellation(); try save(journal, root: p); try checkpoint?(.prepared)
                for (index, target) in plan.source.targets.enumerated() where plan.progress[index].location == .original {
                    try Task.checkCancellation(); try rename(target, root: target.root == .projects ? p : f!, forward: true)
                }
                let staged = try self.plan(journal, projects: projects, files: files)
                guard staged.progress.allSatisfy({ $0.location == .staged }) else { try fail() }
                try checkpoint?(.staged); try Task.checkCancellation(); try checkpoint?(.beforeIrreversible); try Task.checkCancellation()
                journal.phase = .removing; try save(journal, root: p)
            } catch {
                // No unlink has occurred. Restore only still-matching staged
                // targets into free original names; keep a fence on any doubt.
                var restored = true
                for target in plan.source.targets.reversed() {
                    let r = target.root == .projects ? p : f!
                    do {
                        if let info = try statAt(r, target.stage) {
                            guard id(info) == target.resourceIdentity, try statAt(r, target.path) == nil else { try fail() }
                            try rename(target, root: r, forward: false)
                        } else { guard let info = try statAt(r, target.path), id(info) == target.resourceIdentity else { try fail() } }
                    } catch { restored = false }
                }
                if restored { try? unclaim(plan.projectID, root: p) }
                throw error
            }
        }
        // This selected native transaction is now irreversible. Complete or
        // keep exact recovery markers; cancellation never means zero deletion.
        func erase(_ r: Int32, _ path: String, target: BiologyPurgeTarget) throws {
            guard let info = try statAt(r, path) else { return }; guard id(info) == target.resourceIdentity else { try fail() }
            let (parent, name) = try parent(r, path); defer { close(parent) }
            if target.directory {
                let directory = try directoryAt(r, path); defer { close(directory) }
                var count = 0
                func descend(_ fd: Int32, depth: Int) throws {
                    guard depth <= 256 else { try fail() }
                    for child in try names(fd) {
                        count += 1; guard count <= budget else { try fail() }
                        var value = stat(); guard fstatat(fd, child, &value, AT_SYMLINK_NOFOLLOW) == 0 else { try fail() }
                        if value.st_mode & S_IFMT == S_IFDIR {
                            let nested = openat(fd, child, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); guard nested >= 0 else { try fail() }; defer { close(nested) }
                            guard id(try information(nested)) == id(value) else { try fail() }; try descend(nested, depth: depth + 1)
                            var now = stat(); guard fstatat(fd, child, &now, AT_SYMLINK_NOFOLLOW) == 0, id(now) == id(value), unlinkat(fd, child, AT_REMOVEDIR) == 0 else { try fail() }
                        } else { guard unlinkat(fd, child, 0) == 0 else { try fail() } }
                        try checkpoint?(.removedNode)
                    }
                }
                try descend(directory, depth: 0)
                var now = stat(); guard fstatat(parent, name, &now, AT_SYMLINK_NOFOLLOW) == 0, id(now) == target.resourceIdentity, unlinkat(parent, name, AT_REMOVEDIR) == 0 else { try fail() }
            } else { guard unlinkat(parent, name, 0) == 0 else { try fail() }; try checkpoint?(.removedNode) }
        }
        for target in plan.source.targets { try erase(target.root == .projects ? p : f!, target.stage, target: target) }
        let actual = try self.plan(journal, projects: projects, files: files)
        guard actual.progress.allSatisfy({ $0.location == .removed }) else { try fail() }
        try checkpoint?(.beforeCompletion); journal.phase = .complete; try save(journal, root: p)
        _ = try self.plan(journal, projects: projects, files: files)
        return .init(projectID: plan.projectID, transactionID: plan.transactionID, sourceIdentity: plan.sourceIdentity)
    }
}
