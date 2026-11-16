// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin

public struct GameRepositoryLimits: Sendable {
    public let maximumFileBytes: Int
    public let maximumProjectBytes: Int
    public let maximumEntries: Int
    public init(maximumFileBytes: Int = 256 * 1_024 * 1_024,
                maximumProjectBytes: Int = 2 * 1_024 * 1_024 * 1_024, maximumEntries: Int = 10_000) throws {
        guard maximumFileBytes > 0, maximumFileBytes <= 256 * 1_024 * 1_024,
              maximumProjectBytes >= maximumFileBytes, maximumEntries > 0, maximumEntries <= 100_000 else {
            throw GameProjectError.invalidContext
        }
        self.maximumFileBytes = maximumFileBytes; self.maximumProjectBytes = maximumProjectBytes
        self.maximumEntries = maximumEntries
    }
}

public struct GameProjectFile: Codable, Equatable, Sendable {
    public let path: GameRelativePath
    public let sha256: String
    public let bytes: Int
    public let executable: Bool
    public init(path: GameRelativePath, sha256: String, bytes: Int, executable: Bool = false) {
        self.path = path; self.sha256 = sha256; self.bytes = bytes; self.executable = executable
    }
    private enum CodingKeys: String, CodingKey { case path, sha256, bytes, executable }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        path = try values.decode(GameRelativePath.self, forKey: .path)
        sha256 = try values.decode(String.self, forKey: .sha256)
        bytes = try values.decode(Int.self, forKey: .bytes)
        executable = try values.decodeIfPresent(Bool.self, forKey: .executable) ?? false
    }
}

public struct GameStoredProject: Codable, Equatable, Sendable {
    public let version: Int
    public let projectID: UUID
    public let owner: GameProjectOwner
    public let revision: String
    public let parent: String?
    public let title: String
    public let engine: GameEngineID?
    public let directories: [GameRelativePath]
    public let files: [GameProjectFile]
    /// Opaque live-workspace/Git invalidation version; absent in legacy hosts.
    public let workspaceRevision: String?

    public init(version: Int, projectID: UUID, owner: GameProjectOwner, revision: String,
                parent: String?, title: String, engine: GameEngineID?,
                directories: [GameRelativePath], files: [GameProjectFile], workspaceRevision: String? = nil) {
        self.version = version; self.projectID = projectID; self.owner = owner
        self.revision = revision; self.parent = parent; self.title = title; self.engine = engine
        self.directories = directories; self.files = files; self.workspaceRevision = workspaceRevision
    }
}

public enum GameFileChange: Sendable {
    case write(GameRelativePath, Data, executable: Bool? = nil)
    case remove(GameRelativePath)
}

/// A structural AI edit references stored files, without sending binary assets
/// through a model response or rewriting their bytes.
public struct GameFileRelocation: Sendable {
    public let from: GameRelativePath
    public let to: GameRelativePath
    public init(from: GameRelativePath, to: GameRelativePath) throws {
        guard from != to else { throw GameProjectError.invalidEdit }
        self.from = from; self.to = to
    }
}

/// Immutable content/history store with an optional existing-workspace port.
/// In live mode the IDE directory is the editable original; objects are history.
/// Standalone qualification retains HEAD-owned content and explicit exports.
/// Imported project metadata never chooses this repository's owner or project ID.
public actor FileGameProjectRepository {
    public let directory: URL
    public let limits: GameRepositoryLimits
    private let workingTree: (any GameWorkingTreePort)?
    private var capturedBindings: [UUID: GameWorkingTreeBinding] = [:]
    private let maximumMetadataBytes = 32 * 1_024 * 1_024
    private var stagedFiles: [URL] = []
    private var headCommitted = false
    private struct Head: Codable { let revision: String; let sha256: String }

    public init(directory: URL, limits: GameRepositoryLimits? = nil, workingTree: (any GameWorkingTreePort)? = nil) throws {
        guard directory.isFileURL else { throw GameProjectError.invalidContext }
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.limits = limits ?? (try! GameRepositoryLimits())
        self.workingTree = workingTree
        try GameFileStorage.directory(self.directory)
        try GameFileStorage.directory(self.directory.appendingPathComponent("Objects"))
    }

    /// User flow starts with a real, independently owned empty project. Import
    /// is a later revision of this project, not an implicit second project.
    public func createProject(projectID: UUID, owner: GameProjectOwner, title: String,
                              engine: GameEngineID? = nil) throws -> GameStoredProject {
        try validateIdentity(projectID, owner: owner, title: title)
        return try locked(projectID) {
            guard !FileManager.default.fileExists(atPath: headURL(projectID).path) else { throw GameProjectError.destinationExists }
            // Attach to the already host-owned live workspace. Existing IDE
            // files are adopted as history; never replace them with an empty
            // materialization when adding game capabilities to a code project.
            if let snapshot = try liveSnapshot(projectID, owner: owner), let workingTree {
                try validate(GameStoredProject(version: 1, projectID: projectID, owner: owner,
                    revision: UUID().uuidString.lowercased(), parent: nil, title: title, engine: engine,
                    directories: snapshot.directories, files: snapshot.files, workspaceRevision: snapshot.revision))
                var files: [GameProjectFile] = []
                for file in snapshot.files {
                    let data = try workingTree.read(file, snapshot: snapshot, limits: limits)
                    guard data.count == file.bytes, GameDigest.sha256(data) == file.sha256 else {
                        throw GameProjectError.corruptStorage
                    }
                    files.append(try put(data, path: file.path, executable: file.executable))
                }
                guard snapshot == (try workingTree.snapshot(projectID: projectID, owner: owner, limits: limits)) else {
                    throw GameProjectError.invalidContext
                }
                let attached = GameStoredProject(version: 1, projectID: projectID, owner: owner,
                    revision: UUID().uuidString.lowercased(), parent: nil, title: title, engine: engine,
                    directories: snapshot.directories, files: files, workspaceRevision: snapshot.revision)
                return try publish(attached, synchronizeWorkingTree: false)
            }
            let project = GameStoredProject(version: 1, projectID: projectID, owner: owner,
                revision: UUID().uuidString.lowercased(), parent: nil, title: title, engine: engine, directories: [], files: [])
            try validate(project)
            return try publish(project)
        }
    }

    /// Imports the ENTIRE unpacked tree, including unknown files and nested
    /// engines. Engine/root recognition and AI organization happen afterwards.
    /// An explicit replacement retains the previous content in immutable history.
    public func importContents(from source: URL, into projectID: UUID, owner: GameProjectOwner,
                               expectedRevision: String, replaceExisting: Bool = false) throws -> GameStoredProject {
        try locked(projectID) {
            let current = try load(projectID, owner: owner)
            try requireRevision(current, expectedRevision)
            guard replaceExisting || (current.files.isEmpty && current.directories.isEmpty) else { throw GameProjectError.importDestinationNotEmpty }
            let reader = try GameProjectReader(rootURL: source, maximumFileBytes: limits.maximumFileBytes)
            let sourcePath = reader.rootURL.path + "/", storagePath = directory.path + "/"
            guard !storagePath.hasPrefix(sourcePath), !sourcePath.hasPrefix(storagePath) else { throw GameProjectError.invalidContext }
            let entries = try reader.tree(maximumEntries: limits.maximumEntries)
            var files: [GameProjectFile] = [], total = 0
            for item in entries where !item.directory {
                try Task.checkCancellation()
                let file = try put(reader: reader, path: item.path)
                guard total <= limits.maximumProjectBytes - file.bytes else { throw GameProjectError.limitExceeded("projectBytes") }
                total += file.bytes
                files.append(file)
            }
            let finalEntries = try reader.tree(maximumEntries: limits.maximumEntries)
            guard entries.map(\.path) == finalEntries.map(\.path), entries.map(\.directory) == finalEntries.map(\.directory) else { throw GameProjectError.corruptStorage }
            for file in files {
                guard let actual = try reader.fingerprint(file.path), actual.bytes == file.bytes,
                      actual.sha256 == file.sha256 else { throw GameProjectError.corruptStorage }
            }
            let imported = GameStoredProject(version: 1, projectID: projectID, owner: owner,
                revision: UUID().uuidString.lowercased(), parent: current.revision, title: current.title, engine: current.engine,
                directories: entries.filter(\.directory).map(\.path), files: files)
            try validate(imported)
            return try publishImported(imported)
        }
    }

    /// Compatibility helper for trusted component fixtures. Product import UI
    /// uses createProject followed by importContents on that same identity.
    public func importProject(from source: URL, projectID: UUID, owner: GameProjectOwner,
                              title: String, engine: GameEngineID? = nil) throws -> GameStoredProject {
        try validateIdentity(projectID, owner: owner, title: title)
        return try locked(projectID) {
            guard !FileManager.default.fileExists(atPath: headURL(projectID).path) else { throw GameProjectError.destinationExists }
            let reader = try GameProjectReader(rootURL: source, maximumFileBytes: limits.maximumFileBytes)
            let entries = try reader.tree(maximumEntries: limits.maximumEntries)
            // A repository cannot import itself or one of its managed children.
            let sourcePath = reader.rootURL.path + "/", storagePath = directory.path + "/"
            guard !storagePath.hasPrefix(sourcePath), !sourcePath.hasPrefix(storagePath) else { throw GameProjectError.invalidContext }
            var files: [GameProjectFile] = [], total = 0
            for entry in entries where !entry.directory {
                try Task.checkCancellation()
                let file = try put(reader: reader, path: entry.path)
                guard total <= limits.maximumProjectBytes - file.bytes else { throw GameProjectError.limitExceeded("projectBytes") }
                total += file.bytes
                files.append(file)
            }
            let result = GameStoredProject(version: 1, projectID: projectID, owner: owner,
                revision: UUID().uuidString.lowercased(), parent: nil, title: title, engine: engine,
                directories: entries.filter(\.directory).map(\.path), files: files)
            try validate(result)
            // Re-read the source inventory and bytes before accepting a potentially
            // changing external folder. Production hosts also coordinate the source lease.
            let finalEntries = try reader.tree(maximumEntries: limits.maximumEntries)
            guard entries.map({ $0.path }) == finalEntries.map({ $0.path }),
                  entries.map({ $0.directory }) == finalEntries.map({ $0.directory }) else { throw GameProjectError.corruptStorage }
            for file in result.files {
                guard let actual = try reader.fingerprint(file.path), actual.bytes == file.bytes, actual.sha256 == file.sha256 else {
                    throw GameProjectError.unreadableFile(file.path.value)
                }
            }
            return try publishImported(result)
        }
    }

    public func open(_ id: UUID, owner: GameProjectOwner) throws -> GameStoredProject {
        try locked(id) { try load(id, owner: owner) }
    }

    public func openWorkingProject(_ id: UUID, owner: GameProjectOwner) throws -> GameWorkingProjectSnapshot {
        try locked(id) {
            let project = try load(id, owner: owner)
            guard workingTree != nil, let binding = capturedBindings[id] else { throw GameProjectError.invalidContext }
            return .init(project: project, binding: binding)
        }
    }

    /// Exact base bytes for a draft/three-way rebase, without restoring that
    /// historical snapshot over the live IDE. Only reachable owned history is read.
    public func readHistorical(_ id: UUID, owner: GameProjectOwner, expectedRevision: String,
                               historicalRevision: String, path: GameRelativePath) throws -> Data {
        try locked(id) {
            let current = try load(id, owner: owner)
            try requireRevision(current, expectedRevision)
            let original = try reachableRevision(from: current, revision: historicalRevision)
            guard let file = original.files.first(where: { $0.path == path }) else { throw GameProjectError.unreadableFile(path.value) }
            return try object(file)
        }
    }

    public func read(_ id: UUID, owner: GameProjectOwner, revision: String, path: GameRelativePath) throws -> Data {
        try locked(id) {
            // Context/open and commit validate the whole live tree. Repeating
            // that scan for every selected AI text file would hash all binary
            // assets up to 32 times. A pinned read instead verifies its own
            // exact live bytes plus the host/Git version before returning.
            let stored = try loadStored(id, owner: owner)
            let project: GameStoredProject
            if workingTree != nil, capturedBindings[id] != nil, stored.workspaceRevision != nil { project = stored }
            else { project = try load(id, owner: owner) }
            try requireRevision(project, revision)
            guard let file = project.files.first(where: { $0.path == path }) else { throw GameProjectError.unreadableFile(path.value) }
            if let workingTree, let binding = capturedBindings[id], let version = project.workspaceRevision {
                let snapshot = try GameWorkingTreeSnapshot(binding: binding, revision: version,
                    directories: project.directories, files: project.files)
                _ = try workingTree.read(file, snapshot: snapshot, limits: limits)
            }
            return try object(file)
        }
    }

    public func commit(_ id: UUID, owner: GameProjectOwner, expectedRevision: String,
                       changes: [GameFileChange], title: String? = nil) throws -> GameStoredProject {
        try locked(id) {
            let current = try load(id, owner: owner)
            try requireRevision(current, expectedRevision)
            var files = Dictionary(uniqueKeysWithValues: current.files.map { ($0.path, $0) })
            var changed = Set<GameRelativePath>()
            for change in changes {
                try Task.checkCancellation()
                switch change {
                case .write(let path, let data, let executable):
                    guard changed.insert(path).inserted else { throw GameProjectError.invalidEdit }
                    files[path] = try put(data, path: path, executable: executable ?? files[path]?.executable ?? false)
                case .remove(let path):
                    guard changed.insert(path).inserted, files.removeValue(forKey: path) != nil else { throw GameProjectError.invalidEdit }
                }
            }
            var directories = Set(current.directories)
            for path in files.keys {
                let parts = path.value.split(separator: "/")
                for count in 1..<parts.count { directories.insert(try GameRelativePath(parts.prefix(count).joined(separator: "/"))) }
            }
            let result = GameStoredProject(version: 1, projectID: id, owner: owner,
                revision: UUID().uuidString.lowercased(), parent: current.revision, title: title ?? current.title, engine: current.engine,
                directories: directories.sorted { $0.value < $1.value }, files: files.values.sorted { $0.path.value < $1.path.value })
            try validate(result)
            return try publish(result)
        }
    }

    /// Moves/renames are one atomic revision and reuse verified immutable blobs.
    /// Cyclic renames are supported; collisions cannot overwrite another file.
    public func relocateFiles(_ id: UUID, owner: GameProjectOwner, expectedRevision: String,
                              moves: [GameFileRelocation], removeEmptyDirectories: Bool = false) throws -> GameStoredProject {
        guard !moves.isEmpty, moves.count <= limits.maximumEntries else { throw GameProjectError.invalidEdit }
        return try locked(id) {
            let current = try load(id, owner: owner)
            try requireRevision(current, expectedRevision)
            let original = Dictionary(uniqueKeysWithValues: current.files.map { ($0.path, $0) })
            let sources = Set(moves.map(\.from)), targets = Set(moves.map(\.to))
            guard sources.count == moves.count, targets.count == moves.count,
                  sources.allSatisfy({ original[$0] != nil }),
                  targets.allSatisfy({ original[$0] == nil || sources.contains($0) }) else { throw GameProjectError.invalidEdit }
            var files = original
            for path in sources { files.removeValue(forKey: path) }
            for move in moves {
                try Task.checkCancellation()
                guard let record = original[move.from] else { throw GameProjectError.invalidEdit }
                _ = try object(record)
                files[move.to] = .init(path: move.to, sha256: record.sha256, bytes: record.bytes, executable: record.executable)
            }
            var directories: Set<GameRelativePath> = removeEmptyDirectories ? [] : Set(current.directories)
            for path in files.keys {
                let components = path.value.split(separator: "/")
                for count in 1..<components.count { directories.insert(try GameRelativePath(components.prefix(count).joined(separator: "/"))) }
            }
            let organized = GameStoredProject(version: 1, projectID: id, owner: owner,
                revision: UUID().uuidString.lowercased(), parent: current.revision, title: current.title, engine: current.engine,
                directories: directories.sorted { $0.value < $1.value }, files: files.values.sorted { $0.path.value < $1.path.value })
            try validate(organized)
            return try publish(organized)
        }
    }

    public func history(_ id: UUID, owner: GameProjectOwner, limit: Int = 32) throws -> [GameStoredProject] {
        guard (1...1_024).contains(limit) else { throw GameProjectError.invalidContext }
        return try locked(id) {
            var current = try load(id, owner: owner), result: [GameStoredProject] = []
            var visited = Set<String>()
            while result.count < limit {
                guard visited.insert(current.revision).inserted else { throw GameProjectError.corruptStorage }
                result.append(current)
                guard let parent = current.parent else { break }
                current = try loadRevision(id, revision: parent)
                guard current.owner == owner else { throw GameProjectError.ownershipMismatch }
            }
            return result
        }
    }

    public func restore(_ id: UUID, owner: GameProjectOwner, expectedRevision: String,
                        historicalRevision: String) throws -> GameStoredProject {
        try locked(id) {
            let current = try load(id, owner: owner)
            try requireRevision(current, expectedRevision)
            let old = try loadRevision(id, revision: historicalRevision)
            guard old.owner == owner else { throw GameProjectError.ownershipMismatch }
            for file in old.files { _ = try object(file) }
            return try publish(.init(version: 1, projectID: id, owner: owner, revision: UUID().uuidString.lowercased(),
                parent: current.revision, title: old.title, engine: old.engine, directories: old.directories, files: old.files))
        }
    }

    public func copy(_ id: UUID, owner: GameProjectOwner, to newID: UUID,
                     newOwner: GameProjectOwner, title: String? = nil) throws -> GameStoredProject {
        // Immutable blobs can be shared; neither HEAD nor assistant ownership is shared.
        let source = try locked(id) { try load(id, owner: owner) }
        try validateIdentity(newID, owner: newOwner, title: title ?? source.title)
        return try locked(newID) {
            guard !FileManager.default.fileExists(atPath: headURL(newID).path) else { throw GameProjectError.destinationExists }
            for file in source.files { _ = try object(file) }
            return try publish(.init(version: 1, projectID: newID, owner: newOwner, revision: UUID().uuidString.lowercased(),
                parent: nil, title: title ?? source.title, engine: source.engine, directories: source.directories, files: source.files))
        }
    }

    /// Explicit save/import/update between two independent projects. Both
    /// revisions are compared under the same repository lock; no sync link or
    /// shared assistant is created. The destination's previous version survives.
    public func updateCopy(from sourceID: UUID, sourceOwner: GameProjectOwner, sourceRevision: String,
                           to targetID: UUID, targetOwner: GameProjectOwner, expectedTargetRevision: String) throws -> GameStoredProject {
        guard sourceID != targetID else { throw GameProjectError.invalidEdit }
        return try locked(targetID) {
            let source = try load(sourceID, owner: sourceOwner), target = try load(targetID, owner: targetOwner)
            try requireRevision(source, sourceRevision)
            try requireRevision(target, expectedTargetRevision)
            for file in source.files { try Task.checkCancellation(); _ = try object(file) }
            let result = GameStoredProject(version: 1, projectID: targetID, owner: targetOwner,
                revision: UUID().uuidString.lowercased(), parent: target.revision, title: target.title,
                engine: source.engine, directories: source.directories, files: source.files)
            try validate(result)
            return try publish(result)
        }
    }

    /// Atomic publication of a new folder. Existing destinations are preserved.
    public func export(_ id: UUID, owner: GameProjectOwner, expectedRevision: String, to target: URL) throws -> GameProjectContext {
        try locked(id) {
            let project = try load(id, owner: owner)
            try requireRevision(project, expectedRevision)
            return try exportFiles(project, to: target)
        }
    }

    /// Exports an owned, reachable historical snapshot without promoting it
    /// over the live IDE. This also recovers full imported administrative data.
    public func exportHistorical(_ id: UUID, owner: GameProjectOwner, expectedRevision: String,
                                 historicalRevision: String, to target: URL) throws -> GameProjectContext {
        try locked(id) {
            let project = try load(id, owner: owner)
            try requireRevision(project, expectedRevision)
            return try exportFiles(reachableRevision(from: project, revision: historicalRevision), to: target)
        }
    }

    private func reachableRevision(from current: GameStoredProject, revision: String) throws -> GameStoredProject {
        var project = current, visited = Set<String>()
        for _ in 0..<1_024 {
            guard project.owner == current.owner, visited.insert(project.revision).inserted else { throw GameProjectError.corruptStorage }
            if project.revision == revision { return project }
            guard let parent = project.parent else { throw GameProjectError.invalidEdit }
            project = try loadRevision(current.projectID, revision: parent)
        }
        throw GameProjectError.limitExceeded("historyDepth")
    }

    private func exportFiles(_ project: GameStoredProject, to target: URL) throws -> GameProjectContext {
        guard target.isFileURL, !FileManager.default.fileExists(atPath: target.path) else { throw GameProjectError.destinationExists }
        let parent = target.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        try GameFileStorage.directory(parent)
        let stage = parent.appendingPathComponent(".game-export-" + UUID().uuidString)
        try GameFileStorage.directory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        for path in project.directories { try GameFileStorage.directory(stage.appendingPathComponent(path.value)) }
        for file in project.files {
            try Task.checkCancellation()
            try GameFileStorage.atomicWrite(object(file), to: stage.appendingPathComponent(file.path.value))
            if file.executable { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stage.appendingPathComponent(file.path.value).path) }
        }
        try Task.checkCancellation()
        guard renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, target.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw GameProjectError.destinationExists }
            throw GameProjectError.io("publish export")
        }
        return try .init(projectID: project.projectID, owner: project.owner, rootURL: target, savedRevision: project.revision)
    }

    private func projectURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString.lowercased()) }
    private func headURL(_ id: UUID) -> URL { projectURL(id).appendingPathComponent("HEAD.json") }
    private func revisionURL(_ id: UUID, _ revision: String) throws -> URL {
        guard UUID(uuidString: revision)?.uuidString.lowercased() == revision else { throw GameProjectError.corruptStorage }
        return projectURL(id).appendingPathComponent("Revisions/" + revision + ".json")
    }
    private func locked<T>(_ id: UUID, _ operation: () throws -> T) throws -> T {
        // A shared repository lock also protects cross-project blob publication
        // and rollback. No collector can remove another writer's staged object.
        try GameFileStorage.locked(root: directory, name: ".repository.lock") {
            stagedFiles = []; headCommitted = false
            defer { stagedFiles = []; headCommitted = false }
            do { return try operation() }
            catch {
                if !headCommitted { for file in stagedFiles { try? FileManager.default.removeItem(at: file) } }
                throw error
            }
        }
    }
    private func validateIdentity(_ id: UUID, owner: GameProjectOwner, title: String) throws {
        guard GameProjectContext.validIdentifier(title) else { throw GameProjectError.invalidContext }
        if case .space(let recordID) = owner, id != recordID { throw GameProjectError.ownershipMismatch }
    }
    private func validate(_ project: GameStoredProject) throws {
        try validateIdentity(project.projectID, owner: project.owner, title: project.title)
        guard project.workspaceRevision.map(GameProjectContext.validIdentifier) ?? true else { throw GameProjectError.corruptStorage }
        guard project.version == 1, UUID(uuidString: project.revision) != nil,
              project.parent.map({ UUID(uuidString: $0) != nil }) ?? true,
              project.files.count + project.directories.count <= limits.maximumEntries else { throw GameProjectError.corruptStorage }
        var names = Set<String>(), directories = Set<GameRelativePath>(), total = 0
        for path in project.directories {
            guard names.insert(path.value.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw GameProjectError.invalidEdit }
            directories.insert(path)
        }
        for file in project.files {
            guard file.bytes >= 0, file.bytes <= limits.maximumFileBytes,
                  validDigest(file.sha256), names.insert(file.path.value.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  total <= limits.maximumProjectBytes - file.bytes else { throw GameProjectError.limitExceeded("projectFiles") }
            total += file.bytes
            let parts = file.path.value.split(separator: "/")
            for count in 1..<parts.count {
                guard directories.contains(try GameRelativePath(parts.prefix(count).joined(separator: "/"))) else { throw GameProjectError.corruptStorage }
            }
        }
    }
    private func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func objectURL(_ digest: String) throws -> URL {
        guard validDigest(digest) else { throw GameProjectError.corruptStorage }
        return directory.appendingPathComponent("Objects/" + digest)
    }
    private func object(_ file: GameProjectFile) throws -> Data {
        let bytes = try GameFileStorage.read(objectURL(file.sha256), maximum: limits.maximumFileBytes)
        guard bytes.count == file.bytes, GameDigest.sha256(bytes) == file.sha256 else { throw GameProjectError.corruptStorage }
        return bytes
    }
    private func put(reader: GameProjectReader, path: GameRelativePath) throws -> GameProjectFile {
        let temporary = directory.appendingPathComponent("Objects/.game-import-" + UUID().uuidString)
        let descriptor = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw GameProjectError.io("stage import") }
        defer { Darwin.close(descriptor); unlink(temporary.path) }
        guard let fingerprint = try reader.fingerprint(path, writeChunk: { chunk in
            try chunk.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try Task.checkCancellation()
                    let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw GameProjectError.io("write import") }
                    offset += count
                }
            }
        }) else { throw GameProjectError.unreadableFile(path.value) }
        guard fsync(descriptor) == 0 else { throw GameProjectError.io("flush import") }
        let file = GameProjectFile(path: path, sha256: fingerprint.sha256, bytes: fingerprint.bytes,
                                   executable: try reader.isExecutable(path))
        let target = try objectURL(file.sha256)
        try Task.checkCancellation()
        if link(temporary.path, target.path) == 0 {
            stagedFiles.append(target)
            let parent = Darwin.open(target.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw GameProjectError.io("open import directory") }
            defer { Darwin.close(parent) }
            guard fsync(parent) == 0 else { throw GameProjectError.io("flush import directory") }
        } else if errno == EEXIST {
            let existing = try GameProjectReader(rootURL: target.deletingLastPathComponent(), maximumFileBytes: limits.maximumFileBytes)
            guard let actual = try existing.fingerprint(GameRelativePath(target.lastPathComponent)),
                  actual.bytes == file.bytes, actual.sha256 == file.sha256 else { throw GameProjectError.corruptStorage }
        } else { throw GameProjectError.io("commit import") }
        return file
    }
    private func put(_ bytes: Data, path: GameRelativePath, executable: Bool = false) throws -> GameProjectFile {
        guard bytes.count <= limits.maximumFileBytes else { throw GameProjectError.limitExceeded(path.value) }
        let file = GameProjectFile(path: path, sha256: GameDigest.sha256(bytes), bytes: bytes.count, executable: executable)
        let target = try objectURL(file.sha256)
        if FileManager.default.fileExists(atPath: target.path) { _ = try object(file) }
        else { try GameFileStorage.atomicWrite(bytes, to: target); stagedFiles.append(target) }
        return file
    }
    private func requireRevision(_ project: GameStoredProject, _ expected: String) throws {
        guard expected == project.revision else { throw GameProjectError.conflict(expected: expected, actual: project.revision) }
    }
    private func loadRevision(_ id: UUID, revision: String) throws -> GameStoredProject {
        let url = try revisionURL(id, revision)
        let data = try GameFileStorage.read(url, maximum: maximumMetadataBytes)
        let digest = try GameFileStorage.read(url.appendingPathExtension("sha256"), maximum: 128)
        guard String(data: digest, encoding: .utf8) == GameDigest.sha256(data) else { throw GameProjectError.corruptStorage }
        let project = try JSONDecoder().decode(GameStoredProject.self, from: data)
        guard project.projectID == id, project.revision == revision else { throw GameProjectError.corruptStorage }
        try validate(project)
        return project
    }
    private func loadStored(_ id: UUID, owner: GameProjectOwner, honorCancellation: Bool = true) throws -> GameStoredProject {
        guard FileManager.default.fileExists(atPath: headURL(id).path) else { throw GameProjectError.projectNotFound(id) }
        let head = try JSONDecoder().decode(Head.self, from: GameFileStorage.read(headURL(id), maximum: 4_096, honorCancellation: honorCancellation))
        let bytes = try GameFileStorage.read(revisionURL(id, head.revision), maximum: maximumMetadataBytes, honorCancellation: honorCancellation)
        guard GameDigest.sha256(bytes) == head.sha256 else { throw GameProjectError.corruptStorage }
        let result = try JSONDecoder().decode(GameStoredProject.self, from: bytes)
        guard result.projectID == id, result.revision == head.revision else { throw GameProjectError.corruptStorage }
        try validate(result)
        guard result.owner == owner else { throw GameProjectError.ownershipMismatch }
        return result
    }
    private func liveSnapshot(_ id: UUID, owner: GameProjectOwner) throws -> GameWorkingTreeSnapshot? {
        guard let workingTree else { return nil }
        let snapshot = try workingTree.snapshot(projectID: id, owner: owner, limits: limits)
        guard snapshot.binding.projectID == id, snapshot.binding.owner == owner else {
            throw GameProjectError.ownershipMismatch
        }
        if let previous = capturedBindings[id], previous != snapshot.binding {
            throw GameProjectError.contextChanged(previous.environmentID == snapshot.binding.environmentID ? .root : .environment)
        }
        capturedBindings[id] = snapshot.binding
        return snapshot
    }

    private func load(_ id: UUID, owner: GameProjectOwner, honorCancellation: Bool = true) throws -> GameStoredProject {
        let stored = try loadStored(id, owner: owner, honorCancellation: honorCancellation)
        guard honorCancellation, let snapshot = try liveSnapshot(id, owner: owner), let workingTree else { return stored }
        try validate(GameStoredProject(version: 1, projectID: id, owner: owner, revision: stored.revision,
            parent: stored.parent, title: stored.title, engine: stored.engine,
            directories: snapshot.directories, files: snapshot.files, workspaceRevision: snapshot.revision))
        if snapshot.files == stored.files, snapshot.directories == stored.directories,
           snapshot.revision == stored.workspaceRevision { return stored }
        var files: [GameProjectFile] = []
        for file in snapshot.files {
            try Task.checkCancellation()
            if let original = stored.files.first(where: { $0 == file }) { files.append(original); continue }
            let data = try workingTree.read(file, snapshot: snapshot, limits: limits)
            guard data.count == file.bytes, GameDigest.sha256(data) == file.sha256 else { throw GameProjectError.corruptStorage }
            files.append(try put(data, path: file.path, executable: file.executable))
        }
        let after = try workingTree.snapshot(projectID: id, owner: owner, limits: limits)
        guard snapshot == after else { throw GameProjectError.conflict(expected: snapshot.revision, actual: after.revision) }
        let adopted = GameStoredProject(version: 1, projectID: id, owner: owner,
            revision: UUID().uuidString.lowercased(), parent: stored.revision,
            title: stored.title, engine: stored.engine, directories: snapshot.directories, files: files,
            workspaceRevision: snapshot.revision)
        return try publish(adopted, synchronizeWorkingTree: false)
    }

    private func publishImported(_ original: GameStoredProject) throws -> GameStoredProject {
        guard let workingTree else { return try publish(original) }
        let selected = try workingTree.importedTree(original, limits: limits)
        if selected.files == original.files, selected.directories == original.directories { return try publish(original) }
        let files = Dictionary(uniqueKeysWithValues: original.files.map { ($0.path, $0) })
        let directories = Set(original.directories)
        guard selected.files.allSatisfy({ files[$0.path] == $0 }),
              selected.directories.allSatisfy({ directories.contains($0) }) else { throw GameProjectError.invalidEdit }
        let live = GameStoredProject(version: original.version, projectID: original.projectID, owner: original.owner,
            revision: UUID().uuidString.lowercased(), parent: original.revision, title: original.title, engine: original.engine,
            directories: selected.directories, files: selected.files)
        try validate(live)
        // One complete immutable parent retains every original byte, including
        // .git, without creating a second editable workspace or duplicating
        // content-addressed blobs. A failed publication rolls this stage back.
        try stageRevision(original)
        return try publish(live)
    }

    private func publish(_ project: GameStoredProject, synchronizeWorkingTree: Bool = true) throws -> GameStoredProject {
        var published = false
        func metadata(_ workspaceRevision: String?) throws {
            guard !published else { throw GameProjectError.invalidEdit }
            let value = GameStoredProject(version: project.version, projectID: project.projectID, owner: project.owner,
                revision: project.revision, parent: project.parent, title: project.title, engine: project.engine,
                directories: project.directories, files: project.files, workspaceRevision: workspaceRevision)
            try publishMetadata(value)
            published = true
        }
        if synchronizeWorkingTree, let workingTree {
            _ = try liveSnapshot(project.projectID, owner: project.owner)
            let previous = FileManager.default.fileExists(atPath: headURL(project.projectID).path)
                ? try loadStored(project.projectID, owner: project.owner) : nil
            try workingTree.transact(project: project, previous: previous, limits: limits,
                readObject: { try object($0) }, objectURL: { try objectURL($0.sha256) }, publishMetadata: metadata)
        } else { try metadata(project.workspaceRevision) }
        guard published else { throw GameProjectError.invalidEdit }
        return try loadStored(project.projectID, owner: project.owner, honorCancellation: false)
    }

    private func publishMetadata(_ project: GameStoredProject) throws {
        let bytes = try stageRevision(project)
        try Task.checkCancellation()
        let head = Head(revision: project.revision, sha256: GameDigest.sha256(bytes))
        try GameFileStorage.atomicWrite(GameFileStorage.encode(head), to: headURL(project.projectID))
        headCommitted = true
        // Once HEAD committed, report its actual saved state, even if cancellation arrived.
        return
    }

    @discardableResult
    private func stageRevision(_ project: GameStoredProject) throws -> Data {
        try validate(project)
        try GameFileStorage.directory(projectURL(project.projectID).appendingPathComponent("Revisions"))
        let bytes = try GameFileStorage.encode(project)
        guard bytes.count <= maximumMetadataBytes else { throw GameProjectError.limitExceeded("revisionMetadata") }
        let revisionFile = try revisionURL(project.projectID, project.revision)
        try GameFileStorage.atomicWrite(bytes, to: revisionFile)
        stagedFiles.append(revisionFile)
        let checksum = revisionFile.appendingPathExtension("sha256")
        try GameFileStorage.atomicWrite(Data(GameDigest.sha256(bytes).utf8), to: checksum)
        stagedFiles.append(checksum)
        return bytes
    }
}
