// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin
import CryptoKit
import FloeGameCore

public enum RPGDeploymentSelection: Hashable, Sendable {
    case rgssArchive(GameRelativePath)
    /// Select the exact root by its standard data/System.json. Nested projects
    /// with their own System.json remain separate and are not decoded with this key.
    case encryptedMedia(systemJSON: GameRelativePath)

    public var path: GameRelativePath {
        switch self {
        case .rgssArchive(let path), .encryptedMedia(let path): path
        }
    }
}

public enum RPGDeploymentCollisionPolicy: String, Sendable {
    case fail, preferLoose, preferDecoded
}

public struct RPGDeploymentPlannedFile: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case write, remove }
    public let path: GameRelativePath
    public let action: Action
    public let bytes: Int
    public let sha256: String?
}

public struct RPGDeploymentPreparation: Sendable {
    public let id: UUID
    public let context: GameProjectContext
    public let files: [RPGDeploymentPlannedFile]
    public let originalBackupRoot: GameRelativePath
    public let activeGameRoot: GameRelativePath?
    /// Diagnostic/recovery material; not a second authoritative project.
    public let stagingDirectory: URL
}

public struct RPGDeploymentCommit: Sendable {
    public let project: GameStoredProject
    public let originalRevision: String
    public let originalBackupRoot: GameRelativePath
    public let activeGameRoot: GameRelativePath?
}

/// A data-only second stage AFTER whole-tree import into an already created
/// project. No engine recognition gates import. No project, script, executable
/// or DLL runs. Identity/environment come from the host, never imported files.
public actor RPGDeploymentService {
    private struct Pending {
        let preparation: RPGDeploymentPreparation
        let stagedWrites: [GameRelativePath: URL]
    }
    private let repository: FileGameProjectRepository
    private let workspace: URL
    private let limits: RPGDeploymentLimits
    private var pending: [UUID: Pending] = [:]
    private var committing = Set<UUID>()
    private var assetCopies: [UUID: URL] = [:]

    public init(repository: FileGameProjectRepository, workspace: URL,
                limits: RPGDeploymentLimits = .standard) throws {
        guard workspace.isFileURL else { throw RPGDeploymentError.unsafePath("workspace") }
        self.repository = repository
        self.workspace = workspace.standardizedFileURL.resolvingSymlinksInPath()
        self.limits = limits
    }

    /// Host supplies a freshly resolved current context at both preparation
    /// and commit. The repository independently enforces owner and revision CAS.
    public func prepare(context: GameProjectContext, current: GameProjectContext,
                        selection: RPGDeploymentSelection,
                        collisionPolicy: RPGDeploymentCollisionPolicy = .fail) async throws -> RPGDeploymentPreparation {
        try context.validate(current: current)
        let snapshot = try await repository.open(context.projectID, owner: context.owner)
        guard snapshot.revision == context.savedRevision else {
            throw GameProjectError.conflict(expected: context.savedRevision, actual: snapshot.revision)
        }
        let repoRoot = await repository.directory
        for root in [repoRoot, context.rootURL] {
            let a = workspace.path + "/", b = root.path + "/"
            guard !a.hasPrefix(b), !b.hasPrefix(a) else { throw RPGDeploymentError.unsafePath("workspace overlap") }
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let id = UUID(), stage = workspace.appendingPathComponent("rpg-prepare-" + id.uuidString.lowercased())
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        do {
            let backupRoot = try GameRelativePath(".floe-originals-" + id.uuidString.lowercased())
            let backupPrefix = backupRoot.value + "/"
            guard !snapshot.files.contains(where: { $0.path.value == backupRoot.value || $0.path.value.hasPrefix(backupPrefix) }),
                  !snapshot.directories.contains(backupRoot) else { throw RPGDeploymentError.conflictingPath(backupRoot.value) }
            var existing: [String: GameProjectFile] = [:]
            for file in snapshot.files {
                guard existing.updateValue(file, forKey: DeploymentPath.collisionKey(file.path)) == nil else {
                    throw RPGDeploymentError.conflictingPath(file.path.value)
                }
            }
            let directories = Set(snapshot.directories.map(DeploymentPath.collisionKey))
            var files: [RPGDeploymentPlannedFile] = [], writes: [GameRelativePath: URL] = [:]
            var planned = Set<GameRelativePath>(), total: UInt64 = 0
            let repositoryLimits = await repository.limits
            func write(_ bytes: Data, _ path: GameRelativePath) throws {
                guard planned.insert(path).inserted else { throw RPGDeploymentError.conflictingPath(path.value) }
                guard bytes.count <= repositoryLimits.maximumFileBytes,
                      UInt64(bytes.count) <= limits.maximumEntryBytes,
                      UInt64(bytes.count) <= limits.maximumTotalBytes - total else { throw RPGDeploymentError.limitExceeded("prepared bytes") }
                total += UInt64(bytes.count)
                let target = stage.appendingPathComponent("write-" + String(files.count))
                try bytes.write(to: target, options: .withoutOverwriting)
                writes[path] = target
                files.append(.init(path: path, action: .write, bytes: bytes.count, sha256: digest(bytes)))
            }
            func remove(_ path: GameRelativePath) throws {
                guard planned.insert(path).inserted else { throw RPGDeploymentError.conflictingPath(path.value) }
                files.append(.init(path: path, action: .remove, bytes: 0, sha256: nil))
            }
            func place(_ bytes: Data, at path: GameRelativePath, originalLoose: Data?) throws {
                let key = DeploymentPath.collisionKey(path)
                guard !directories.contains(key) else { throw RPGDeploymentError.conflictingPath(path.value) }
                if let loose = existing[key] {
                    if loose.path == path && loose.sha256 == digest(bytes) { return }
                    switch collisionPolicy {
                    case .fail: throw RPGDeploymentError.conflictingPath(path.value)
                    case .preferLoose: return
                    case .preferDecoded:
                        guard let old = originalLoose, digest(old) == loose.sha256 else { throw RPGDeploymentError.sourceChanged }
                        try write(old, GameRelativePath(backupPrefix + "Loose/" + loose.path.value))
                        if loose.path != path { try remove(loose.path) }
                    }
                }
                try write(bytes, path)
            }
            let activeRoot: GameRelativePath?
            switch selection {
            case .rgssArchive(let archive):
                guard let record = snapshot.files.first(where: { $0.path == archive }) else { throw RPGDeploymentError.invalidSelection }
                let original = try await repository.read(context.projectID, owner: context.owner, revision: context.savedRevision, path: archive)
                guard digest(original) == record.sha256 else { throw RPGDeploymentError.sourceChanged }
                let input = stage.appendingPathComponent("original.rgss")
                try original.write(to: input, options: .withoutOverwriting)
                let extracted = try RGSSArchive.extract(at: input, to: stage.appendingPathComponent("decoded"), limits: limits)
                let parts = archive.value.split(separator: "/").dropLast().joined(separator: "/")
                activeRoot = parts.isEmpty ? nil : try GameRelativePath(parts)
                for entry in extracted.files {
                    try Task.checkCancellation()
                    let path = try GameRelativePath(parts.isEmpty ? entry.path : parts + "/" + entry.path)
                    guard path != archive else { throw RPGDeploymentError.conflictingPath(path.value) }
                    let bytes = try stagedBytes(extracted.output.appendingPathComponent(entry.path), maximum: repositoryLimits.maximumFileBytes)
                    guard digest(bytes) == entry.sha256 else { throw RPGDeploymentError.sourceChanged }
                    var oldLoose: Data?
                    if collisionPolicy == .preferDecoded, let loose = existing[DeploymentPath.collisionKey(path)],
                       loose.path != path || loose.sha256 != entry.sha256 {
                        oldLoose = try await repository.read(context.projectID, owner: context.owner,
                                                            revision: context.savedRevision, path: loose.path)
                    }
                    try place(bytes, at: path, originalLoose: oldLoose)
                }
                // Keeping the active archive would cause the original Windows
                // player to prefer old encrypted data over newly edited loose data.
                // The explicit plan moves its exact bytes to this owned backup;
                // the original full revision also remains in immutable history.
                try write(original, GameRelativePath(backupPrefix + "Archive/" + archive.value))
                try remove(archive)
            case .encryptedMedia(let system):
                let components = system.value.split(separator: "/")
                guard components.count >= 2, components.last?.lowercased() == "system.json",
                      components[components.count - 2].lowercased() == "data" else { throw RPGDeploymentError.invalidSelection }
                let root = components.dropLast(2).joined(separator: "/")
                activeRoot = root.isEmpty ? nil : try GameRelativePath(root)
                let prefix = root.isEmpty ? "" : root + "/"
                let nestedRoots = snapshot.files.compactMap { file -> String? in
                    let parts = file.path.value.split(separator: "/")
                    guard file.path != system, file.path.value.hasPrefix(prefix), parts.count >= 2,
                          parts.last?.lowercased() == "system.json", parts[parts.count - 2].lowercased() == "data" else { return nil }
                    let nested = parts.dropLast(2).joined(separator: "/")
                    return nested == root ? nil : nested + "/"
                }
                let source = try await repository.read(context.projectID, owner: context.owner, revision: context.savedRevision, path: system)
                var images = false, audio = false, count = 0
                for file in snapshot.files where file.path.value.hasPrefix(prefix) && !nestedRoots.contains(where: { file.path.value.hasPrefix($0) }) {
                    guard let plain = try RPGEncryptedMedia.plaintextPath(for: file.path) else { continue }
                    try Task.checkCancellation()
                    let encrypted = try await repository.read(context.projectID, owner: context.owner, revision: context.savedRevision, path: file.path)
                    let decoded = try RPGEncryptedMedia.decode(encrypted, systemJSON: source, maximumBytes: repositoryLimits.maximumFileBytes)
                    try RPGEncryptedMedia.validatePlaintext(decoded, path: plain)
                    var oldLoose: Data?
                    if collisionPolicy == .preferDecoded, let loose = existing[DeploymentPath.collisionKey(plain)],
                       loose.path != plain || loose.sha256 != digest(decoded) {
                        oldLoose = try await repository.read(context.projectID, owner: context.owner,
                                                            revision: context.savedRevision, path: loose.path)
                    }
                    try place(decoded, at: plain, originalLoose: oldLoose)
                    if plain.value.lowercased().hasSuffix(".png") { images = true } else { audio = true }
                    count += 1
                }
                guard count > 0 else { throw RPGDeploymentError.invalidSelection }
                try write(source, GameRelativePath(backupPrefix + "System/" + system.value))
                try write(RPGEncryptedMedia.plaintextSystem(source, images: images, audio: audio), system)
            }
            guard files.count <= repositoryLimits.maximumEntries else { throw RPGDeploymentError.limitExceeded("prepared files") }
            var projected = Dictionary(uniqueKeysWithValues: snapshot.files.map { ($0.path, $0.bytes) })
            var projectedDirectories = Set(snapshot.directories)
            for file in files {
                if file.action == .remove { projected.removeValue(forKey: file.path) }
                else { projected[file.path] = file.bytes }
            }
            for path in projected.keys {
                let parts = path.value.split(separator: "/")
                for count in 1..<parts.count { projectedDirectories.insert(try GameRelativePath(parts.prefix(count).joined(separator: "/"))) }
            }
            guard projected.count + projectedDirectories.count <= repositoryLimits.maximumEntries,
                  projected.values.reduce(0, +) <= repositoryLimits.maximumProjectBytes else { throw RPGDeploymentError.limitExceeded("resulting project") }
            try DeploymentPath.validateSet(projected.map { .init(path: $0.key, originalNameBytes: Data(), byteCount: UInt64($0.value), offset: 0, fileKey: 0) })
            let preparation = RPGDeploymentPreparation(id: id, context: context, files: files,
                originalBackupRoot: backupRoot, activeGameRoot: activeRoot, stagingDirectory: stage)
            // Receipt contains hashes and file names, never the project media key.
            try JSONEncoder().encode(files).write(to: stage.appendingPathComponent("PREPARATION.json"), options: .withoutOverwriting)
            try Task.checkCancellation()
            let latest = try await repository.open(context.projectID, owner: context.owner)
            guard latest.revision == context.savedRevision else { throw GameProjectError.conflict(expected: context.savedRevision, actual: latest.revision) }
            pending[id] = .init(preparation: preparation, stagedWrites: writes)
            return preparation
        } catch {
            let receipt = ["result": "not-committed", "originalRevision": context.savedRevision,
                           "stage": stage.lastPathComponent, "error": String(describing: error)]
            if let bytes = try? JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]) {
                try? bytes.write(to: stage.appendingPathComponent("FAILURE.json"), options: .atomic)
            }
            throw error
        }
    }

    public func commit(_ id: UUID, current: GameProjectContext) async throws -> RPGDeploymentCommit {
        guard let item = pending[id] else { throw RPGDeploymentError.preparationNotFound }
        let preparation = item.preparation
        try preparation.context.validate(current: current)
        guard committing.insert(id).inserted else { throw RPGDeploymentError.operationInProgress }
        defer { committing.remove(id) }
        let repositoryLimits = await repository.limits
        var changes: [GameFileChange] = []
        for file in preparation.files {
            try Task.checkCancellation()
            switch file.action {
            case .remove: changes.append(.remove(file.path))
            case .write:
                guard let url = item.stagedWrites[file.path] else { throw RPGDeploymentError.sourceChanged }
                let bytes = try stagedBytes(url, maximum: repositoryLimits.maximumFileBytes)
                guard bytes.count == file.bytes, digest(bytes) == file.sha256 else { throw RPGDeploymentError.sourceChanged }
                changes.append(.write(file.path, bytes))
            }
        }
        let context = preparation.context
        let committed = try await repository.commit(context.projectID, owner: context.owner,
                                                      expectedRevision: context.savedRevision, changes: changes)
        pending.removeValue(forKey: id)
        // The authoritative commit already contains all exact originals and
        // historical revision. A cleanup failure cannot turn success into failure.
        try? FileManager.default.removeItem(at: preparation.stagingDirectory)
        return .init(project: committed, originalRevision: context.savedRevision,
                     originalBackupRoot: preparation.originalBackupRoot, activeGameRoot: preparation.activeGameRoot)
    }

    /// Explicit discard is confined to this instance's owned pending operation.
    public func discard(_ id: UUID) throws {
        guard !committing.contains(id) else { throw RPGDeploymentError.operationInProgress }
        guard let item = pending.removeValue(forKey: id) else { throw RPGDeploymentError.preparationNotFound }
        try FileManager.default.removeItem(at: item.preparation.stagingDirectory)
    }
}

/// Paths are relative to the selected game's payload. An export contains
/// copies and carries no project-edit or commit operation.
public struct RPGDeploymentAssets: Sendable, Identifiable {
    public struct File: Sendable, Hashable {
        public let path: GameRelativePath
        public let bytes: UInt64
    }
    public let id: UUID
    public let files: [File]
    public let directory: URL?
}

extension RPGDeploymentService {
    public static func availableAssets(in project: GameStoredProject, engine: GameEngineID,
                                       selectedRoot: GameRelativePath?) -> [RPGDeploymentSelection] {
        let prefix = selectedRoot.map { $0.value + "/" } ?? ""
        let archiveExtension: String
        switch engine {
        case .rpgMakerXP: archiveExtension = "rgssad"
        case .rpgMakerVX: archiveExtension = "rgss2a"
        case .rpgMakerVXAce: archiveExtension = "rgss3a"
        case .rpgMakerMV, .rpgMakerMZ:
            return project.files.compactMap { file in
                guard file.path.value.hasPrefix(prefix) else { return nil }
                let local = file.path.value.dropFirst(prefix.count).lowercased()
                guard local == "data/system.json" || local == "www/data/system.json",
                      !webSources(in: project, system: file.path, engine: engine).isEmpty else { return nil }
                return .encryptedMedia(systemJSON: file.path)
            }.sorted { $0.path.value < $1.path.value }
        default: return []
        }
        return project.files.compactMap { file in
            guard file.path.value.hasPrefix(prefix) else { return nil }
            let name = file.path.value.dropFirst(prefix.count)
            guard !name.contains("/"), name.lowercased().hasSuffix("." + archiveExtension) else { return nil }
            return .rgssArchive(file.path)
        }.sorted { $0.path.value < $1.path.value }
    }

    private static func webSources(in project: GameStoredProject, system: GameRelativePath,
                                   engine: GameEngineID) -> [GameProjectFile] {
        let prefix = webPrefix(system)
        let extensions = engine == .rpgMakerMV ? ["rpgmvp", "rpgmvo", "rpgmvm"] : ["png_", "ogg_", "m4a_"]
        let nested = project.files.compactMap { file -> String? in
            guard file.path != system, file.path.value.hasPrefix(prefix),
                  file.path.value.lowercased().hasSuffix("/data/system.json") else { return nil }
            let child = webPrefix(file.path)
            return child == prefix ? nil : child
        }
        return project.files.filter { file in
            guard file.path.value.hasPrefix(prefix) else { return false }
            let local = file.path.value.dropFirst(prefix.count).lowercased()
            guard local.hasPrefix("img/") || local.hasPrefix("audio/"),
                  extensions.contains(where: { local.hasSuffix("." + $0) }) else { return false }
            return !nested.contains(where: { file.path.value.hasPrefix($0) })
        }
    }

    private static func webPrefix(_ system: GameRelativePath) -> String {
        let root = system.value.split(separator: "/").dropLast(2).joined(separator: "/")
        return root.isEmpty ? "" : root + "/"
    }

    /// Reads one saved revision under the host's current project identity.
    /// A list uses archive metadata only. Export independently verifies and
    /// decodes the data before handing an owned directory to the Files picker.
    public func readAssets(context: GameProjectContext, current: GameProjectContext,
                           engine: GameEngineID, selectedRoot: GameRelativePath?,
                           selection: RPGDeploymentSelection, export: Bool) async throws -> RPGDeploymentAssets {
        try Task.checkCancellation()
        try context.validate(current: current)
        func snapshot() async throws -> GameStoredProject {
            let value = try await repository.open(context.projectID, owner: context.owner)
            guard value.revision == context.savedRevision else {
                throw GameProjectError.conflict(expected: context.savedRevision, actual: value.revision)
            }
            return value
        }
        let project = try await snapshot()
        guard Self.availableAssets(in: project, engine: engine, selectedRoot: selectedRoot).contains(selection)
        else { throw RPGDeploymentError.invalidSelection }
        for root in [await repository.directory, context.rootURL] {
            let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            guard !(workspace.path + "/").hasPrefix(rootPath), !rootPath.hasPrefix(workspace.path + "/")
            else { throw RPGDeploymentError.unsafePath("workspace overlap") }
        }
        try Task.checkCancellation()
        let id = UUID()
        let stage = workspace.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        var retainCopy = false
        defer { if !retainCopy { try? FileManager.default.removeItem(at: stage) } }
        let output = stage.appendingPathComponent("RPG Assets", isDirectory: true)
        let listing: [RPGDeploymentAssets.File]
        switch selection {
        case .rgssArchive(let archive):
            let record = try await repository.read(context.projectID, owner: context.owner,
                                                   revision: context.savedRevision, path: archive)
            guard UInt64(record.count) <= limits.maximumArchiveBytes else {
                throw RPGDeploymentError.limitExceeded("archive")
            }
            let source = stage.appendingPathComponent("archive")
            try record.write(to: source, options: .withoutOverwriting)
            let expectedVersion = engine == .rpgMakerVXAce ? 3 : 1
            if export {
                let result = try RGSSArchive.extract(at: source, to: output, limits: limits)
                guard result.archiveVersion == expectedVersion else { throw RPGDeploymentError.invalidSelection }
                listing = try result.files.map { .init(path: try GameRelativePath($0.path), bytes: $0.byteCount) }
            } else {
                let result = try RGSSArchive.inspect(at: source, limits: limits)
                guard result.version == expectedVersion else { throw RPGDeploymentError.invalidSelection }
                listing = result.entries.map { .init(path: $0.path, bytes: $0.byteCount) }
            }
            try FileManager.default.removeItem(at: source)
        case .encryptedMedia(let system):
            listing = try await mediaAssets(system: system, engine: engine, project: project,
                                            context: context, output: export ? output : nil)
        }
        _ = try await snapshot()
        try Task.checkCancellation()
        if export {
            assetCopies[id] = stage
            retainCopy = true
        }
        return .init(id: id, files: listing.sorted { $0.path.value < $1.path.value }, directory: export ? output : nil)
    }

    private func mediaAssets(system: GameRelativePath, engine: GameEngineID, project: GameStoredProject,
                             context: GameProjectContext, output: URL?) async throws -> [RPGDeploymentAssets.File] {
        let sources = Self.webSources(in: project, system: system, engine: engine)
        guard sources.count <= limits.maximumFiles else { throw RPGDeploymentError.limitExceeded("media files") }
        let prefix = Self.webPrefix(system)
        var total: UInt64 = 0
        let files: [RPGDeploymentAssets.File] = try sources.map { source in
            try Task.checkCancellation()
            guard let path = try RPGEncryptedMedia.plaintextPath(for: GameRelativePath(String(source.path.value.dropFirst(prefix.count)))),
                  source.bytes >= 32 else { throw RPGDeploymentError.invalidMediaHeader }
            let count = UInt64(source.bytes - 16)
            guard count <= limits.maximumEntryBytes, count <= limits.maximumTotalBytes - total
            else { throw RPGDeploymentError.limitExceeded("media bytes") }
            total += count
            return .init(path: path, bytes: count)
        }
        try DeploymentPath.validateSet(files.map { .init(path: $0.path, originalNameBytes: Data(),
                                                         byteCount: $0.bytes, offset: 0, fileKey: 0) })
        if let output {
            let systemBytes = try await repository.read(context.projectID, owner: context.owner,
                                                        revision: context.savedRevision, path: system)
            let maxFile = await repository.limits.maximumFileBytes
            for (source, file) in zip(sources, files) {
                try Task.checkCancellation()
                let encrypted = try await repository.read(context.projectID, owner: context.owner,
                                                          revision: context.savedRevision, path: source.path)
                let decoded = try RPGEncryptedMedia.decode(encrypted, systemJSON: systemBytes, maximumBytes: maxFile)
                try RPGEncryptedMedia.validatePlaintext(decoded, path: file.path)
                guard UInt64(decoded.count) == file.bytes else { throw RPGDeploymentError.sourceChanged }
                let destination = output.appendingPathComponent(file.path.value)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try decoded.write(to: destination, options: .withoutOverwriting)
            }
        }
        return files
    }

    public func discardAssetCopy(_ id: UUID) throws {
        guard let directory = assetCopies[id] else { return }
        try FileManager.default.removeItem(at: directory)
        assetCopies.removeValue(forKey: id)
    }
}

private func digest(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

/// Staging is host-owned; still refuse a late replacement symlink or FIFO.
private func stagedBytes(_ url: URL, maximum: Int) throws -> Data {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw RPGDeploymentError.sourceChanged }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_size >= 0, info.st_size <= maximum else { throw RPGDeploymentError.limitExceeded("staged bytes") }
    var result = Data()
    while let part = try handle.read(upToCount: min(64 * 1_024, maximum + 1 - result.count)), !part.isEmpty {
        try Task.checkCancellation()
        guard part.count <= maximum - result.count else { throw RPGDeploymentError.limitExceeded("staged bytes") }
        result.append(part)
    }
    guard result.count == info.st_size else { throw RPGDeploymentError.sourceChanged }
    return result
}
