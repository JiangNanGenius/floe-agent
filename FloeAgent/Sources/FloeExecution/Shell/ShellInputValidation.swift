import Foundation
import FloeCore

/// Shared validation for tool, editor and terminal entry points.
public enum ShellInputValidation {
    public static func validate(command: String, cwd: String, environment: [String: String], stdin: String? = nil) throws {
        guard command.utf8.count <= 16 * 1024, !command.contains("\0") else {
            throw FloeError.validationFailed("Shell command exceeds 16 KiB or contains NUL")
        }
        guard !cwd.hasPrefix("/"), !cwd.hasPrefix("~"), !cwd.contains("\0"),
              !cwd.split(separator: "/").contains("..") else {
            throw FloeError.validationFailed("cwd must be a workspace-relative path without '..'")
        }
        guard environment.count <= 32 else { throw FloeError.validationFailed("Too many environment variables") }
        for (key, value) in environment {
            guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
                  value.utf8.count <= 16 * 1024, !value.contains("\0") else {
                throw FloeError.validationFailed("Invalid shell environment variable")
            }
            guard !["HOME", "TMPDIR", "PATH", "PYTHONHOME", "PYTHONPATH"].contains(key),
                  !key.hasPrefix("DYLD_"), !key.hasPrefix("LD_") else {
                throw FloeError.validationFailed("The shell manages its own runtime paths")
            }
        }
        guard (stdin?.utf8.count ?? 0) <= 256 * 1024 else {
            throw FloeError.validationFailed("stdin exceeds 256 KiB")
        }
    }

    public static func directory(cwd: String, root: URL) throws -> URL {
        try validate(command: "", cwd: cwd, environment: [:])
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let directory = canonicalRoot.appendingPathComponent(cwd).resolvingSymlinksInPath().standardizedFileURL
        guard directory.path == canonicalRoot.path || directory.path.hasPrefix(canonicalRoot.path + "/") else {
            throw FloeError.validationFailed("cwd resolves outside the workspace")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FloeError.validationFailed("cwd is not an existing directory")
        }
        return directory
    }

    /// Never splits a UTF-8 scalar or exceeds the byte limit.
    public static func prefix(_ text: String, maxBytes: Int) -> String {
        var bytes = Array(text.utf8.prefix(max(0, maxBytes)))
        while !bytes.isEmpty {
            if let value = String(bytes: bytes, encoding: .utf8) { return value }
            bytes.removeLast()
        }
        return ""
    }
}
