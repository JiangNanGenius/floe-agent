// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import ZIPFoundation

public enum GameArchiveError: Error, Equatable, Sendable {
    case unreadableArchive
    case emptyArchive
    case unsafeEntryPath(String)
    case symlinkEntry(String)
    case duplicateEntry(String)
    case caseCollision(String)
    case ancestorCollision(String)
    case checksumMismatch(String)
    case truncatedEntry(String)
    case entryLimitExceeded(Int)
    case fileLimitExceeded(String)
    case projectLimitExceeded
    case invalidRootChoice(String)
    case destinationExists(String)
    case unsafeSourceEntry(String)
    case invalidTarget
    case limitExceeded(String)
    case io(String)
}

public struct GameArchiveExchangeLimits: Sendable {
    public let maximumFileBytes: Int
    public let maximumProjectBytes: Int
    public let maximumEntries: Int
    public let maximumDepth: Int

    public init(maximumFileBytes: Int = 64 * 1_024 * 1_024,
                maximumProjectBytes: Int = 512 * 1_024 * 1_024,
                maximumEntries: Int = 10_000,
                maximumDepth: Int = 32) throws {
        guard maximumFileBytes > 0, maximumFileBytes <= 256 * 1_024 * 1_024,
              maximumProjectBytes >= maximumFileBytes,
              maximumEntries > 0, maximumEntries <= 100_000,
              maximumDepth > 0, maximumDepth <= 128 else {
            throw GameArchiveError.limitExceeded("invalidLimits")
        }
        self.maximumFileBytes = maximumFileBytes
        self.maximumProjectBytes = maximumProjectBytes
        self.maximumEntries = maximumEntries
        self.maximumDepth = maximumDepth
    }
}

public enum GameArchiveEntryKind: String, Sendable {
    case file, directory, symlink, other
}

public struct GameArchiveEntryPreview: Equatable, Sendable {
    public let path: String
    public let kind: GameArchiveEntryKind
    public let uncompressedBytes: Int
}

public struct GameArchiveRootCandidate: Equatable, Sendable {
    public let name: String
    public let isDirectory: Bool
    public let containsProjectMarkers: Bool
}

public struct GameArchiveListing: Sendable {
    public let entries: [GameArchiveEntryPreview]
    public let rootCandidates: [GameArchiveRootCandidate]
    public let topLevelNames: [String]
}

/// Extraction is always explicit: the caller either keeps the archive layout
/// (`asIs`) or names the single top-level container whose prefix is stripped.
/// This component never silently selects the first (or only) nested project.
public enum GameArchiveRootChoice: Equatable, Sendable {
    case asIs
    case container(String)
}

public struct GameArchiveManifest: Equatable, Sendable {
    public let files: [GameProjectFile]
    public let directories: [GameRelativePath]
    public var executablePaths: [GameRelativePath] { files.filter(\.executable).map(\.path) }
}

public struct GameArchiveExtraction: Sendable {
    public let rootURL: URL
    public let manifest: GameArchiveManifest
    public let originalArchiveSHA256: String
}

public struct GameArchivePublication: Sendable {
    public let archiveURL: URL
    public let sha256: String
    public let manifest: GameArchiveManifest
    public let entryCount: Int
}

/// Real ZIP exchange on top of the reviewed ZIPFoundation vendor. Import is a
/// validate-everything-first pipeline over in-memory entry data (ZIPFoundation
/// never touches the filesystem during extraction); publication is staged and
/// exclusive. Export packs a safe directory walk with permissions, empty
/// directories and binary bytes preserved, then re-reads and CRC-checks the
/// produced archive before reporting success.
public struct GameArchiveExchange: Sendable {
    public let limits: GameArchiveExchangeLimits

    public init(limits: GameArchiveExchangeLimits? = nil) {
        self.limits = limits ?? (try! GameArchiveExchangeLimits())
    }

    // MARK: - Inspect

    public func inspect(archive: URL, filenameEncoding: String.Encoding? = nil) throws -> GameArchiveListing {
        let archive = try openArchive(archive, filenameEncoding: filenameEncoding)
        var previews: [GameArchiveEntryPreview] = []
        var topLevel = Set<String>()
        for entry in archive {
            let path = decodedPath(entry, filenameEncoding: filenameEncoding)
            if let first = path.split(separator: "/", omittingEmptySubsequences: true).first {
                topLevel.insert(String(first))
            }
            previews.append(.init(path: path, kind: kind(of: entry), uncompressedBytes: Int(entry.uncompressedSize)))
        }
        guard !previews.isEmpty else { throw GameArchiveError.emptyArchive }
        let candidates = topLevel.sorted().map { name -> GameArchiveRootCandidate in
            let isDirectory = previews.contains { $0.path == name + "/" || $0.path == name }
                && !previews.contains { $0.path == name && $0.kind == .file }
            let markerExtensions: Set<String> = ["rxproj", "rvproj", "rvproj2", "rpgproject", "rmmzproject",
                                                 "godot", "unity", "uproject", "json", "html", "zip"]
            let containsMarkers = previews.contains {
                guard $0.path.hasPrefix(name + "/") else { return false }
                let ext = ($0.path as NSString).pathExtension.lowercased()
                return markerExtensions.contains(ext) || $0.path.lowercased().hasSuffix("project.godot")
                    || $0.path.lowercased().hasSuffix("projectsettings/projectversion.txt")
            }
            return .init(name: name, isDirectory: isDirectory, containsProjectMarkers: containsMarkers)
        }
        return .init(entries: previews, rootCandidates: candidates, topLevelNames: topLevel.sorted())
    }

    // MARK: - Peek (bounded single-entry read for diagnostics)

    /// Read one small text entry (e.g. package.json, RPG_RT.ini) fully in
    /// memory with CRC validation, without extracting the archive. Returns
    /// nil when the entry does not exist; throws on unsafe names, oversize
    /// data or checksum mismatch.
    public func readEntry(archive archiveURL: URL, path: GameRelativePath,
                          maximumBytes: Int = 256 * 1_024,
                          filenameEncoding: String.Encoding? = nil) throws -> Data? {
        guard maximumBytes > 0 else { throw GameArchiveError.limitExceeded("peek") }
        let archive = try openArchive(archiveURL, filenameEncoding: filenameEncoding)
        var found: Entry?
        for entry in archive {
            let decoded = decodedPath(entry, filenameEncoding: filenameEncoding)
            if decoded == path.value || decoded == path.value + "/" {
                found = entry
                break
            }
        }
        guard let entry = found else { return nil }
        guard entry.type == .file else { throw GameArchiveError.unsafeEntryPath(path.value) }
        guard entry.uncompressedSize <= maximumBytes else { throw GameArchiveError.fileLimitExceeded(path.value) }
        return try extractBytes(archive, entry: entry)
    }

    // MARK: - Extract

    public func extract(archive archiveURL: URL, to target: URL,
                        rootChoice: GameArchiveRootChoice = .asIs,
                        filenameEncoding: String.Encoding? = nil) throws -> GameArchiveExtraction {
        guard target.isFileURL, !FileManager.default.fileExists(atPath: target.path) else {
            throw GameArchiveError.destinationExists(target.lastPathComponent)
        }
        let originalBytes = try Data(contentsOf: archiveURL, options: [.mappedIfSafe])
        let archive = try openArchive(archiveURL)
        let plan = try validatedExtractionPlan(archive: archive, rootChoice: rootChoice,
                                               filenameEncoding: filenameEncoding)
        let (stage, publish) = try GameBuildFileSupport.stagedDirectory(near: target, prefix: "floe-import")
        do {
            for directory in plan.directories {
                try Task.checkCancellation()
                try GameBuildFileSupport.makeDirectory(stage.appendingPathComponent(directory.value))
            }
            var files: [GameProjectFile] = []
            for item in plan.files {
                try Task.checkCancellation()
                let data = try extractBytes(archive, entry: item.entry)
                guard data.count == item.entry.uncompressedSize else {
                    throw GameArchiveError.truncatedEntry(item.path.value)
                }
                let record = GameProjectFile(path: item.path, sha256: GameDigest.sha256(data),
                                             bytes: data.count, executable: item.executable)
                let output = stage.appendingPathComponent(item.path.value)
                // Nested files without an explicit directory entry still need
                // their parent directories inside the stage.
                try GameBuildFileSupport.makeDirectory(output.deletingLastPathComponent())
                try GameBuildFileSupport.publish(data, to: output)
                if item.executable {
                    try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                          ofItemAtPath: stage.appendingPathComponent(item.path.value).path)
                }
                files.append(record)
            }
            try Task.checkCancellation()
            try publish()
            let manifest = GameArchiveManifest(files: files.sorted { $0.path.value < $1.path.value },
                                               directories: plan.directories.sorted { $0.value < $1.value })
            return .init(rootURL: target, manifest: manifest,
                         originalArchiveSHA256: GameDigest.sha256(originalBytes))
        } catch {
            try? FileManager.default.removeItem(at: stage)
            throw error
        }
    }

    // MARK: - Archive (export)

    public func archive(directory source: URL, to target: URL, compress: Bool = true) throws -> GameArchivePublication {
        guard target.isFileURL, !FileManager.default.fileExists(atPath: target.path) else {
            throw GameArchiveError.destinationExists(target.lastPathComponent)
        }
        let walker = try GameDirectoryTreeWalker(rootURL: source)
        let entries = try walker.walk(maximumEntries: limits.maximumEntries, maximumDepth: limits.maximumDepth)
        let (stage, _) = try GameBuildFileSupport.stagedDirectory(near: target, prefix: "floe-zip")
        let stagedZIP = stage.appendingPathComponent("archive.zip")
        defer { try? FileManager.default.removeItem(at: stage) }
        var manifestFiles: [GameProjectFile] = []
        var directories: [GameRelativePath] = []
        var total = 0
        do {
            let archive = try Archive(url: stagedZIP, accessMode: .create, pathEncoding: nil)
            for entry in entries {
                try Task.checkCancellation()
                if entry.directory {
                    try archive.addEntry(with: entry.path.value + "/", type: .directory,
                                         uncompressedSize: Int64(0), compressionMethod: .none,
                                         bufferSize: defaultWriteChunkSize, progress: nil) { _, _ in Data() }
                    directories.append(entry.path)
                    continue
                }
                guard entry.bytes <= limits.maximumFileBytes,
                      total <= limits.maximumProjectBytes - entry.bytes else {
                    throw GameArchiveError.fileLimitExceeded(entry.path.value)
                }
                total += entry.bytes
                let sourceFile = source.appendingPathComponent(entry.path.value)
                let handle = try FileHandle(forReadingFrom: sourceFile)
                defer { try? handle.close() }
                let permissions: UInt16 = entry.executable ? 0o755 : 0o644
                var crcData = Data()
                try archive.addEntry(with: entry.path.value, type: .file,
                                     uncompressedSize: Int64(entry.bytes),
                                     permissions: permissions,
                                     compressionMethod: compress ? .deflate : .none,
                                     bufferSize: defaultWriteChunkSize, progress: nil) { position, size in
                    try handle.seek(toOffset: UInt64(position))
                    let chunk = try handle.read(upToCount: size) ?? Data()
                    crcData.append(chunk)
                    return chunk
                }
                let bytes = try Data(contentsOf: sourceFile, options: [.mappedIfSafe])
                guard crcData == bytes else { throw GameArchiveError.io("read during pack \(entry.path.value)") }
                manifestFiles.append(.init(path: entry.path, sha256: GameDigest.sha256(bytes),
                                           bytes: bytes.count, executable: entry.executable))
            }
            try Task.checkCancellation()
            try GameBuildFileSupport.publishFile(from: stagedZIP, to: target)
        } catch {
            throw error
        }
        // The produced archive must itself pass the full import validation,
        // proving our writer is interoperable and CRC-complete.
        let verified = try verifyProducedArchive(at: target, expect: manifestFiles, directories: directories)
        return .init(archiveURL: target, sha256: verified, manifest: .init(files: manifestFiles, directories: directories),
                     entryCount: manifestFiles.count + directories.count)
    }

    // MARK: - Verification

    /// Force-read every entry of a ZIP (CRC validated by ZIPFoundation) and
    /// confirm the entry set matches the expectation. Returns the archive SHA-256.
    @discardableResult
    public func verifyArchive(_ url: URL, expectFiles: [GameProjectFile],
                              expectDirectories: [GameRelativePath],
                              filenameEncoding: String.Encoding? = nil) throws -> String {
        let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
        let archive = try openArchive(url, filenameEncoding: filenameEncoding)
        var seenFiles: [GameProjectFile] = []
        var seenDirs: [GameRelativePath] = []
        for entry in archive {
            try Task.checkCancellation()
            let decoded = decodedPath(entry, filenameEncoding: filenameEncoding)
            switch kind(of: entry) {
            case .file:
                var data = Data()
                _ = try archive.extract(entry) { chunk in data.append(chunk) }
                let path = try validatedRelativePath(decoded)
                seenFiles.append(.init(path: path, sha256: GameDigest.sha256(data),
                                       bytes: data.count, executable: isExecutable(entry)))
            case .directory:
                var path = decoded
                if path.hasSuffix("/") { path.removeLast() }
                seenDirs.append(try validatedRelativePath(path))
            default:
                throw GameArchiveError.symlinkEntry(decoded)
            }
        }
        guard seenFiles.sorted(by: { $0.path.value < $1.path.value }) == expectFiles.sorted(by: { $0.path.value < $1.path.value }),
              seenDirs.sorted(by: { $0.value < $1.value }) == expectDirectories.sorted(by: { $0.value < $1.value }) else {
            throw GameArchiveError.checksumMismatch("archive entry set changed between write and read")
        }
        return GameDigest.sha256(bytes)
    }

    // MARK: - Internals

    private struct PlannedFile {
        let entry: Entry
        let path: GameRelativePath
        let executable: Bool
    }
    private struct ExtractionPlan {
        let files: [PlannedFile]
        let directories: [GameRelativePath]
    }

    private func openArchive(_ url: URL, filenameEncoding: String.Encoding? = nil) throws -> Archive {
        guard url.isFileURL else { throw GameArchiveError.invalidTarget }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw GameArchiveError.unreadableArchive
        }
        // Explicit legacy-encoding override (GBK/Shift-JIS archives). UTF-8 and
        // CP437 archives need no override; wrong selections fail closed in path
        // validation rather than silently relabeling bytes.
        do {
            return try Archive(url: url.standardizedFileURL, accessMode: .read,
                               pathEncoding: filenameEncoding)
        } catch {
            throw GameArchiveError.unreadableArchive
        }
    }

    private func decodedPath(_ entry: Entry, filenameEncoding: String.Encoding?) -> String {
        if let filenameEncoding {
            return entry.path(using: filenameEncoding)
        }
        return entry.path
    }

    private func kind(of entry: Entry) -> GameArchiveEntryKind {
        switch entry.type {
        case .file: return .file
        case .directory: return .directory
        case .symlink: return .symlink
        }
    }

    private func isExecutable(_ entry: Entry) -> Bool {
        guard entry.type == .file else { return false }
        guard let permissions = entry.fileAttributes[.posixPermissions] as? NSNumber else { return false }
        return permissions.uint16Value & 0o100 != 0
    }

    /// Normalize a raw ZIP path into a safe GameRelativePath or throw.
    private func validatedRelativePath(_ raw: String) throws -> GameRelativePath {
        var path = raw
        if path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty else { throw GameArchiveError.unsafeEntryPath(raw) }
        // ZIPFoundation reports codepage437/utf8 decoded names; backslashes and
        // drive letters are never valid project-relative components.
        guard !path.hasPrefix("/") else { throw GameArchiveError.unsafeEntryPath(raw) }
        do {
            return try GameRelativePath(path)
        } catch {
            throw GameArchiveError.unsafeEntryPath(raw)
        }
    }

    private func validatedExtractionPlan(archive: Archive, rootChoice: GameArchiveRootChoice,
                                         filenameEncoding: String.Encoding?) throws -> ExtractionPlan {
        var rawEntries: [(entry: Entry, path: GameRelativePath, kind: GameArchiveEntryKind)] = []
        var count = 0
        for entry in archive {
            try Task.checkCancellation()
            count += 1
            guard count <= limits.maximumEntries else { throw GameArchiveError.entryLimitExceeded(limits.maximumEntries) }
            guard entry.type != .symlink else { throw GameArchiveError.symlinkEntry(decodedPath(entry, filenameEncoding: filenameEncoding)) }
            let path = try validatedRelativePath(decodedPath(entry, filenameEncoding: filenameEncoding))
            let kind: GameArchiveEntryKind = entry.type == .directory ? .directory : .file
            if kind == .file {
                guard entry.uncompressedSize <= limits.maximumFileBytes else {
                    throw GameArchiveError.fileLimitExceeded(path.value)
                }
            }
            rawEntries.append((entry, path, kind))
        }
        guard !rawEntries.isEmpty else { throw GameArchiveError.emptyArchive }
        let stripped = try applyRootChoice(rawEntries, rootChoice: rootChoice)
        let (files, directories) = try planTree(stripped)
        return .init(files: files, directories: directories)
    }

    private func applyRootChoice(_ entries: [(entry: Entry, path: GameRelativePath, kind: GameArchiveEntryKind)],
                                 rootChoice: GameArchiveRootChoice) throws
        -> [(entry: Entry, path: GameRelativePath, kind: GameArchiveEntryKind)] {
        guard case .container(let container) = rootChoice else { return entries }
        guard !container.isEmpty, container.utf8.count <= 256, !container.contains("/"),
              container != ".", container != "..", !container.hasPrefix("."),
              !container.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !container.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GameArchiveError.invalidRootChoice(container)
        }
        var result: [(entry: Entry, path: GameRelativePath, kind: GameArchiveEntryKind)] = []
        for item in entries {
            let value = item.path.value
            guard value == container || value.hasPrefix(container + "/") else {
                // Entries outside the chosen container are dropped, not merged.
                continue
            }
            let stripped: String
            if value == container {
                stripped = ""  // the container itself becomes the root
            } else {
                stripped = String(value.dropFirst(container.count + 1))
            }
            guard !stripped.isEmpty else { continue }
            result.append((item.entry, try GameRelativePath(stripped), item.kind))
        }
        guard !result.isEmpty else { throw GameArchiveError.invalidRootChoice(container) }
        return result
    }

    /// Validate the full entry set as a directory tree: no exact duplicates,
    /// no case-fold duplicates, no file/directory ancestor collisions, bounded total.
    private func planTree(_ entries: [(entry: Entry, path: GameRelativePath, kind: GameArchiveEntryKind)])
        throws -> (files: [PlannedFile], directories: [GameRelativePath]) {
        var exact = Set<String>()
        var folded = Set<String>()
        var kinds: [String: GameArchiveEntryKind] = [:]
        var total = 0
        for item in entries {
            let key = item.path.value
            guard exact.insert(key).inserted else { throw GameArchiveError.duplicateEntry(key) }
            let fold = key.precomposedStringWithCanonicalMapping.lowercased()
            guard folded.insert(fold).inserted else { throw GameArchiveError.caseCollision(key) }
            guard kinds[key] == nil else { throw GameArchiveError.duplicateEntry(key) }
            kinds[key] = item.kind
            if item.kind == .file { total += Int(item.entry.uncompressedSize) }
        }
        guard total <= limits.maximumProjectBytes else { throw GameArchiveError.projectLimitExceeded }
        // Ancestor collision: every proper prefix of any path must not be a file,
        // and a directory prefix must actually exist as a directory when declared.
        for item in entries {
            let parts = item.path.value.split(separator: "/")
            guard parts.count <= limits.maximumDepth else { throw GameArchiveError.limitExceeded("entryDepth") }
            for index in 1..<parts.count {
                let prefix = parts.prefix(index).joined(separator: "/")
                if kinds[prefix] == .file { throw GameArchiveError.ancestorCollision(item.path.value) }
            }
        }
        var files: [PlannedFile] = []
        var directories: [GameRelativePath] = []
        for item in entries {
            if item.kind == .directory {
                directories.append(item.path)
            } else {
                files.append(.init(entry: item.entry, path: item.path, executable: isExecutable(item.entry)))
            }
        }
        return (files, directories)
    }

    private func extractBytes(_ archive: Archive, entry: Entry) throws -> Data {
        var data = Data()
        do {
            let checksum = try archive.extract(entry, bufferSize: 32 * 1_024, skipCRC32: false) { chunk in
                try Task.checkCancellation()
                data.append(chunk)
            }
            // The consumer-based extract returns the computed CRC but does not
            // compare it; validation is the caller's responsibility.
            guard checksum == entry.checksum else {
                throw GameArchiveError.checksumMismatch(entry.path)
            }
        } catch let error as GameArchiveError {
            throw error
        } catch let error as Archive.ArchiveError {
            if error == .invalidCRC32 {
                throw GameArchiveError.checksumMismatch(entry.path)
            }
            throw GameArchiveError.truncatedEntry(entry.path)
        } catch {
            throw GameArchiveError.truncatedEntry(entry.path)
        }
        guard data.count == entry.uncompressedSize else { throw GameArchiveError.truncatedEntry(entry.path) }
        return data
    }

    private func verifyProducedArchive(at url: URL, expect files: [GameProjectFile],
                                       directories: [GameRelativePath]) throws -> String {
        try verifyArchive(url, expectFiles: files, expectDirectories: directories)
    }
}
