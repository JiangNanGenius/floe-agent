// FloeMacTerminal — working-directory scope for a terminal session.
//
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The clearly-scoped folder a terminal session starts in.
///
/// Sessions never silently pick a directory: the user either keeps the
/// home fallback, confirms a project folder that was explicitly handed to
/// the view, or picks a folder themselves in the open panel.
public enum MacTerminalScope: Equatable, Sendable {
    /// The current user's home directory.
    case home
    /// A caller-chosen or user-picked folder (already validated).
    case directory(String)

    /// Validates `path` and returns the scoped directory.
    /// - Throws: `MacTerminalScopeError` when the path is not an existing
    ///   directory readable by the current process.
    public static func validatedDirectory(_ path: String) throws -> MacTerminalScope {
        let standardized = (path as NSString).standardizingPath
        guard !standardized.isEmpty else { throw MacTerminalScopeError.invalidPath(path) }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: standardized, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            throw MacTerminalScopeError.notADirectory(standardized)
        }
        return .directory(standardized)
    }

    /// The POSIX path the child shell starts in.
    public var path: String {
        switch self {
        case .home:
            return NSHomeDirectory()
        case .directory(let path):
            return path
        }
    }

    /// Short label for UI display.
    public var displayName: String {
        switch self {
        case .home:
            return MacTerminalCopy.t("主目录", "Home")
        case .directory(let path):
            return (path as NSString).lastPathComponent
        }
    }
}

public enum MacTerminalScopeError: Error, Equatable, Sendable {
    case invalidPath(String)
    case notADirectory(String)

    public var message: String {
        switch self {
        case .invalidPath(let path):
            return MacTerminalCopy.t("路径无效：\(path)", "Invalid path: \(path)")
        case .notADirectory(let path):
            return MacTerminalCopy.t("不是文件夹：\(path)", "Not a folder: \(path)")
        }
    }
}
