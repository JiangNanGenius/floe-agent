// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A selected private workspace cannot redirect native Git's metadata/object
/// IO into another task through .git/commondir/alternates. Internal linked
/// worktrees and object alternates remain supported inside the selected root.
enum G04GitMetadataBoundary {
    static func validate(root: URL) throws {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let marker = root.appendingPathComponent(".git")
        let manager = FileManager.default
        guard manager.fileExists(atPath: marker.path) ||
                (try? manager.destinationOfSymbolicLink(atPath: marker.path)) != nil else { return }
        func owned(_ url: URL) throws -> URL {
            let value = url.standardizedFileURL.resolvingSymlinksInPath()
            guard value.path == root.path || value.path.hasPrefix(root.path + "/") else {
                throw G04WorkspaceGit.Failure.pathRefused
            }
            return value
        }
        let resolvedMarker = try owned(marker)
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: resolvedMarker.path, isDirectory: &isDirectory) else {
            throw G04WorkspaceGit.Failure.pathRefused
        }
        var gitDirectory = resolvedMarker
        if !isDirectory.boolValue {
            let line = try read(resolvedMarker, maximum: 8192).trimmingCharacters(in: .newlines)
            guard line.hasPrefix("gitdir:") else { throw G04WorkspaceGit.Failure.pathRefused }
            let path = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            gitDirectory = try owned(resolve(path, relativeTo: root))
        }
        let commonFile = gitDirectory.appendingPathComponent("commondir")
        var common = gitDirectory
        if manager.fileExists(atPath: commonFile.path) {
            let path = try read(owned(commonFile), maximum: 8192).trimmingCharacters(in: .newlines)
            common = try owned(resolve(path, relativeTo: gitDirectory))
        }
        let backPointer = gitDirectory.appendingPathComponent("gitdir")
        if manager.fileExists(atPath: backPointer.path) {
            let path = try read(owned(backPointer), maximum: 8192).trimmingCharacters(in: .newlines)
            _ = try owned(resolve(path, relativeTo: gitDirectory))
        }
        var pending = [try owned(common.appendingPathComponent("objects", isDirectory: true))]
        var visited: Set<String> = []
        while let objectDirectory = pending.popLast() {
            if !visited.insert(objectDirectory.path).inserted { continue }
            guard visited.count <= 32 else { throw G04WorkspaceGit.Failure.pathRefused }
            let alternates = objectDirectory.appendingPathComponent("info/alternates")
            guard manager.fileExists(atPath: alternates.path) else { continue }
            let content = try read(owned(alternates), maximum: 64 * 1024)
            for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
                let path = try unquote(String(line))
                pending.append(try owned(resolve(path, relativeTo: objectDirectory)))
            }
        }
    }

    private static func resolve(_ path: String, relativeTo base: URL) throws -> URL {
        guard !path.isEmpty, !path.contains("\0"), path.utf8.count <= 8192 else {
            throw G04WorkspaceGit.Failure.pathRefused
        }
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
    }

    private static func read(_ url: URL, maximum: Int) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value <= Int64(maximum) else {
            throw G04WorkspaceGit.Failure.pathRefused
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum, let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw G04WorkspaceGit.Failure.pathRefused
        }
        return text
    }

    /// Git C-quoted alternate paths, including octal-escaped UTF-8 bytes.
    private static func unquote(_ value: String) throws -> String {
        guard value.hasPrefix("\"") else { return value }
        let bytes = Array(value.utf8)
        guard bytes.count >= 2, bytes.last == 34 else { throw G04WorkspaceGit.Failure.pathRefused }
        var output: [UInt8] = []; var index = 1
        while index < bytes.count - 1 {
            var byte = bytes[index]; index += 1
            if byte == 92 {
                guard index < bytes.count - 1 else { throw G04WorkspaceGit.Failure.pathRefused }
                byte = bytes[index]; index += 1
                if (48...55).contains(byte) {
                    var number = Int(byte - 48); var count = 1
                    while count < 3, index < bytes.count - 1, (48...55).contains(bytes[index]) {
                        number = number * 8 + Int(bytes[index] - 48); index += 1; count += 1
                    }
                    guard number <= 255 else { throw G04WorkspaceGit.Failure.pathRefused }
                    byte = UInt8(number)
                } else {
                    let escaped: [UInt8: UInt8] = [97: 7, 98: 8, 116: 9, 110: 10, 118: 11, 102: 12, 114: 13, 34: 34, 92: 92]
                    guard let result = escaped[byte] else { throw G04WorkspaceGit.Failure.pathRefused }
                    byte = result
                }
            } else if byte == 34 { throw G04WorkspaceGit.Failure.pathRefused }
            output.append(byte)
        }
        guard let path = String(bytes: output, encoding: .utf8), !path.contains("\0") else {
            throw G04WorkspaceGit.Failure.pathRefused
        }
        return path
    }
}
