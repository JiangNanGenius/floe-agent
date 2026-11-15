// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin
import FloeGameCore

/// Bounded, symlink-refusing file access for prepared resources, templates and
/// built artifacts. The App's original-file lease and File Provider grants stay
/// outside this component.
enum GamePortableFileAccess {
    static func read(root: URL, path: String, maximumBytes: Int) throws -> Data {
        let relative = try GameRelativePath(path)
        guard maximumBytes > 0 else { throw GamePortableError.invalidArtifact("read bound") }
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        var url = rootURL
        for component in relative.value.split(separator: "/", omittingEmptySubsequences: false) {
            url.appendPathComponent(String(component), isDirectory: false)
        }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let prefix = rootURL.path + "/"
        guard resolved.path.hasPrefix(prefix) else { throw GamePortableError.invalidArtifact(path) }
        let descriptor = Darwin.open(resolved.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw GamePortableError.io("open \(path)") }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes else {
            throw GamePortableError.invalidArtifact(path)
        }
        var result = Data()
        result.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: min(32_768, maximumBytes + 1))
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress!, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw GamePortableError.io("read \(path)") }
            if count == 0 { return result }
            guard result.count <= maximumBytes - count else {
                throw GamePortableError.limitExceeded(path)
            }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    static func record(root: URL, path: String, maximumBytes: Int) throws -> GamePortableFileRecord {
        let relative = try GameRelativePath(path)
        let data = try read(root: root, path: path, maximumBytes: maximumBytes)
        let executable: Bool
        do { executable = try isExecutable(root: root, path: path) } catch { executable = false }
        return .init(path: relative, sha256: GameDigest.sha256(data), bytes: data.count, executable: executable)
    }

    static func isExecutable(root: URL, path: String) throws -> Bool {
        let relative = try GameRelativePath(path)
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        var url = rootURL
        for component in relative.value.split(separator: "/", omittingEmptySubsequences: false) {
            url.appendPathComponent(String(component), isDirectory: false)
        }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(rootURL.path + "/") else { throw GamePortableError.invalidArtifact(path) }
        let descriptor = Darwin.open(resolved.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw GamePortableError.io("open \(path)") }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw GamePortableError.invalidArtifact(path)
        }
        return (info.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0
    }

    struct Entry: Sendable {
        let path: GameRelativePath
        let directory: Bool
        let bytes: Int
    }

    static func enumerate(root: URL, maximumEntries: Int = 100_000,
                          maximumDepth: Int = 32) throws -> [Entry] {
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: rootURL,
            includingPropertiesForKeys: keys, options: [.skipsPackageDescendants], errorHandler: { _, _ in true }) else {
            throw GamePortableError.io("enumerate")
        }
        var result: [Entry] = []
        let rootPrefix = rootURL.path + "/"
        while let item = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard result.count < maximumEntries else { throw GamePortableError.limitExceeded("treeEntries") }
            let standardized = item.standardizedFileURL
            guard standardized.path.hasPrefix(rootPrefix) else { throw GamePortableError.invalidArtifact("escape") }
            let relative = String(standardized.path.dropFirst(rootPrefix.count))
            guard !relative.isEmpty, relative.split(separator: "/").count <= maximumDepth else {
                throw GamePortableError.limitExceeded("treeDepth")
            }
            let values = try standardized.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else { throw GamePortableError.invalidArtifact(relative) }
            if values.isDirectory == true {
                result.append(.init(path: try GameRelativePath(relative), directory: true, bytes: 0))
            } else if values.isRegularFile == true {
                let bytes = values.fileSize ?? 0
                guard bytes >= 0 else { throw GamePortableError.invalidArtifact(relative) }
                result.append(.init(path: try GameRelativePath(relative), directory: false, bytes: bytes))
            } else {
                throw GamePortableError.invalidArtifact(relative)
            }
        }
        return result.sorted { $0.path.value < $1.path.value }
    }

    static func writeAtomic(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let parentValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true else {
            throw GamePortableError.io("output directory")
        }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw GamePortableError.io("write \(url.lastPathComponent)")
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize == data.count else { throw GamePortableError.io("read back") }
    }

    @discardableResult
    static func copyTree(from source: URL, to destination: URL,
                         maximumEntries: Int = 100_000,
                         maximumBytes: Int = 512 * 1_024 * 1_024) throws -> [GamePortableFileRecord] {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw GamePortableError.destinationExists
        }
        let entries = try enumerate(root: source, maximumEntries: maximumEntries)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var records: [GamePortableFileRecord] = []
        var total = 0
        for entry in entries {
            try Task.checkCancellation()
            let target = destination.appendingPathComponent(entry.path.value)
            if entry.directory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            guard total <= maximumBytes - entry.bytes else { throw GamePortableError.limitExceeded("copyBytes") }
            let data = try read(root: source, path: entry.path.value, maximumBytes: entry.bytes + 1)
            guard data.count == entry.bytes else { throw GamePortableError.invalidArtifact(entry.path.value) }
            try writeAtomic(data, to: target)
            let record = GamePortableFileRecord(path: entry.path, sha256: GameDigest.sha256(data),
                                               bytes: data.count, executable: try isExecutable(root: source, path: entry.path.value))
            if record.executable {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
            }
            total += data.count
            records.append(record)
        }
        return records
    }

    static func removeIfExists(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw GamePortableError.io("directory")
        }
    }
}
