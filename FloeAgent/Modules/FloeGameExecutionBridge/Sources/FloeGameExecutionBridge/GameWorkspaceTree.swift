// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// Bounded, symlink-refusing tree operations used by the execution bridge.
/// The source tree is untrusted imported content; every path is relative and
/// no operation follows a link or accepts `..`.
public enum GameWorkspaceTree {
    public struct Entry: Sendable, Equatable {
        public let path: GameRelativePath
        public let directory: Bool
        public let executable: Bool
        public let bytes: Int
        public let sha256: String?
    }

    public struct Manifest: Sendable, Equatable {
        public let files: [GameProjectFile]
        public let directories: [GameRelativePath]
        public let digest: String
        public let totalBytes: Int
    }

    /// Canonical digest identical to the reviewed CI templates:
    /// `path:sha256:bytes:executable`, sorted, joined with a newline, SHA-256.
    /// `.git`, `.floe` and `out` directories are excluded at every depth.
    public static func manifest(rootURL: URL,
                                limits: GameExecutionLimits = .default,
                                excludedDirectoryNames: Set<String> = [".git", ".floe", "out"]) throws -> Manifest {
        let root = try checkedRoot(rootURL)
        var entries: [Entry] = []
        var files: [GameProjectFile] = []
        var directories: [GameRelativePath] = []
        var total = 0

        func visit(_ directory: URL, prefix: String, depth: Int) throws {
            guard depth <= limits.maximumDepth else {
                throw GameExecutionError.invalidConfiguration("source depth exceeds \(limits.maximumDepth)")
            }
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            for name in names {
                try Task.checkCancellation()
                guard entries.count < limits.maximumEntries else {
                    throw GameExecutionError.invalidConfiguration("source entry count exceeds \(limits.maximumEntries)")
                }
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                let path = try GameRelativePath(relative)
                let url = directory.appendingPathComponent(name)
                let values = try url.resourceValues(forKeys: [
                    .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
                    .fileSizeKey
                ])
                guard values.isSymbolicLink != true else {
                    throw GameExecutionError.artifactInvalid("symbolic link in source: \(relative)")
                }
                if values.isDirectory == true {
                    if excludedDirectoryNames.contains(name) { continue }
                    directories.append(path)
                    entries.append(.init(path: path, directory: true, executable: false,
                                         bytes: 0, sha256: nil))
                    try visit(url, prefix: relative, depth: depth + 1)
                    continue
                }
                guard values.isRegularFile == true else {
                    throw GameExecutionError.artifactInvalid("non-regular file in source: \(relative)")
                }
                let size = values.fileSize ?? 0
                guard size >= 0, size <= limits.maximumFileBytes,
                      total <= limits.maximumProjectBytes - size else {
                    throw GameExecutionError.invalidConfiguration("source file/size limit at \(relative)")
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw GameExecutionError.artifactInvalid("source changed while inspecting: \(relative)")
                }
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                guard data.count == size else {
                    throw GameExecutionError.artifactInvalid("source changed while reading: \(relative)")
                }
                let digest = GameDigest.sha256(data)
                let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
                let executable = (permissions & 0o111) != 0
                total += data.count
                let file = GameProjectFile(path: path, sha256: digest, bytes: data.count,
                                           executable: executable)
                files.append(file)
                entries.append(.init(path: path, directory: false, executable: executable,
                                     bytes: data.count, sha256: digest))
            }
        }

        try visit(root, prefix: "", depth: 0)
        let rows = entries.filter { !$0.directory }.map {
            "\($0.path.value):\($0.sha256 ?? ""):\($0.bytes):\($0.executable ? "1" : "0")"
        }.sorted()
        let digest = GameDigest.sha256(Data(rows.joined(separator: "\n").utf8))
        return .init(files: files.sorted { $0.path.value < $1.path.value },
                     directories: directories.sorted { $0.value < $1.value },
                     digest: digest, totalBytes: total)
    }

    /// Copy exactly the source bytes into a new destination. Existing
    /// destinations are refused; no link or special file is followed.
    @discardableResult
    public static func copyTree(from source: URL, to destination: URL,
                                limits: GameExecutionLimits = .default) throws -> Manifest {
        let root = try checkedRoot(source)
        guard destination.isFileURL else {
            throw GameExecutionError.invalidConfiguration("destination URL")
        }
        let destination = destination.standardizedFileURL
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw GameExecutionError.invalidConfiguration("destination exists")
        }
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let manifest = try self.manifest(rootURL: root, limits: limits)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)

        for directory in manifest.directories {
            try Task.checkCancellation()
            let url = destination.appendingPathComponent(directory.value)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        for file in manifest.files {
            try Task.checkCancellation()
            let sourceURL = root.appendingPathComponent(file.path.value)
            let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
            guard data.count == file.bytes, GameDigest.sha256(data) == file.sha256 else {
                throw GameExecutionError.artifactInvalid("source changed while copying: \(file.path.value)")
            }
            let target = destination.appendingPathComponent(file.path.value)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: target, options: [.withoutOverwriting])
            if file.executable {
                try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                      ofItemAtPath: target.path)
            }
        }
        // Verify the copy byte-for-byte before any build command sees it.
        let copied = try self.manifest(rootURL: destination, limits: limits)
        guard copied.digest == manifest.digest, copied.files == manifest.files else {
            throw GameExecutionError.artifactInvalid("copied source tree does not match its manifest")
        }
        return manifest
    }

    /// Remove only an owned staging directory. Refuse a symlink or a path that
    /// is not a real directory so a later replacement cannot redirect cleanup.
    public static func removeOwnedDirectory(_ url: URL) throws {
        guard url.isFileURL else { throw GameExecutionError.outputEscaped("staging URL") }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }

    /// Copy a directory's contents below an existing output directory. The
    /// output directory must be empty or absent; no existing file is
    /// overwritten, and every copied file is read back through the manifest.
    @discardableResult
    public static func publishContents(of source: URL, to output: URL,
                                       expectedEntry: GameRelativePath,
                                       limits: GameExecutionLimits = .default) throws -> Manifest {
        let source = try checkedRoot(source)
        let outputPath = output.standardizedFileURL.resolvingSymlinksInPath().path
        guard outputPath != source.path, !outputPath.hasPrefix(source.path + "/") else {
            throw GameExecutionError.outputEscaped("output is inside the published source")
        }
        let manifest = try self.manifest(
            rootURL: source, limits: limits, excludedDirectoryNames: [])
        guard manifest.files.contains(where: { $0.path == expectedEntry }) else {
            throw GameExecutionError.artifactInvalid("expected entry \(expectedEntry.value) is missing")
        }
        if FileManager.default.fileExists(atPath: output.path) {
            let values = try output.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw GameExecutionError.invalidConfiguration("output is not a real directory")
            }
            let names = try FileManager.default.contentsOfDirectory(atPath: output.path)
            guard names.isEmpty else {
                throw GameExecutionError.invalidConfiguration("output directory is not empty")
            }
        } else {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        }
        for directory in manifest.directories {
            try FileManager.default.createDirectory(
                at: output.appendingPathComponent(directory.value),
                withIntermediateDirectories: true)
        }
        for file in manifest.files {
            try Task.checkCancellation()
            let data = try Data(contentsOf: source.appendingPathComponent(file.path.value),
                                options: [.mappedIfSafe])
            guard data.count == file.bytes, GameDigest.sha256(data) == file.sha256 else {
                throw GameExecutionError.artifactInvalid("artifact changed while publishing: \(file.path.value)")
            }
            let target = output.appendingPathComponent(file.path.value)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: target, options: [.withoutOverwriting])
            if file.executable {
                try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                      ofItemAtPath: target.path)
            }
        }
        let copied = try self.manifest(
            rootURL: output, limits: limits, excludedDirectoryNames: [])
        guard copied.digest == manifest.digest, copied.files == manifest.files else {
            throw GameExecutionError.artifactInvalid("published artifact does not match its manifest")
        }
        return copied
    }

    private static func checkedRoot(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw GameExecutionError.invalidConfiguration("source URL") }
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw GameExecutionError.invalidConfiguration("source is not a real directory")
        }
        return root
    }

}
