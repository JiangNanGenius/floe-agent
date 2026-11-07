// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin

public enum LaTeXPath {
    public static func validate(_ path: String) throws -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 4096, !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
            throw LaTeXError.invalidPath(path)
        }
        return path
    }
    public static func child(_ path: String, root: URL, createParents: Bool = false) throws -> URL {
        _ = try validate(path)
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        var current = base
        for (index, part) in path.split(separator: "/").enumerated() {
            current.appendPathComponent(String(part))
            if let info = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]), info.isSymbolicLink == true { throw LaTeXError.invalidPath(path) }
            let canonical = current.resolvingSymlinksInPath().standardizedFileURL
            guard canonical.path.hasPrefix(base.path + "/") else { throw LaTeXError.invalidPath(path) }
            if createParents && index < path.split(separator: "/").count - 1 {
                var directory: ObjCBool = false
                if FileManager.default.fileExists(atPath: current.path, isDirectory: &directory) {
                    guard directory.boolValue else { throw LaTeXError.invalidPath(path) }
                } else {
                    try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
                }
            }
        }
        return current
    }
    public static func collisionKey(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
}

enum LaTeXFileLock {
    static func run<T>(root: URL, _ body: () throws -> T) throws -> T {
        let url = root.appendingPathComponent(".latex.lock")
        let fd = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }
}
