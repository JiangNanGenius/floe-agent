// FloeWorkspace — Structured errors for workspace tools.
// See docs/ARCHITECTURE_AGENT_WORKSPACE.md §3/§6: every failure raised by
// workspace tools is a `WorkspaceToolError`, encoded into the failed
// `ToolResult.outputSummary` so the model and UI see a stable, parseable
// shape instead of an opaque localized string.

import Foundation

/// Structured error raised by the workspace path guard, file service, and
/// file tools. Encodes into a stable JSON envelope for failed tool results.
public enum WorkspaceToolError: Error, Sendable, Equatable {
    /// Path resolves outside the workspace root (traversal or symlink).
    case escapesRoot(String)
    /// Path hits the secret-file exclusion list.
    case secretFile(String)
    /// Payload or file exceeds the configured byte cap.
    case tooLarge(limit: Int)
    /// Target does not exist.
    case notFound(String)
    /// Optimistic-concurrency conflict (mtime + sha256 mismatch).
    case conflict(expected: String, actual: String)
    /// create_file target already exists.
    case alreadyExists(String)
    /// Operation requires a file but found a directory (or vice versa).
    case isDirectory(String)
    /// Tool was invoked with an unsupported execution scope (e.g. host).
    case unsupportedScope(String)
    /// Malformed or inapplicable unified diff.
    case invalidPatch(String)
    /// Arguments failed schema-level validation.
    case invalidArguments(String)
}

extension WorkspaceToolError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .escapesRoot(let path):
            "Path escapes the workspace root: \(path)"
        case .secretFile(let path):
            "Path is a protected secret file: \(path)"
        case .tooLarge(let limit):
            "File or payload exceeds the \(limit)-byte limit"
        case .notFound(let path):
            "No such file or directory: \(path)"
        case .conflict(let expected, let actual):
            "Write conflict: expected \(expected) but found \(actual)"
        case .alreadyExists(let path):
            "File already exists: \(path)"
        case .isDirectory(let path):
            "Path is a directory: \(path)"
        case .unsupportedScope(let scope):
            "Unsupported execution scope for workspace tools: \(scope)"
        case .invalidPatch(let reason):
            "Invalid patch: \(reason)"
        case .invalidArguments(let reason):
            "Invalid arguments: \(reason)"
        }
    }
}

public extension WorkspaceToolError {
    /// Machine-readable stable code for the error case.
    var code: String {
        switch self {
        case .escapesRoot: "escapesRoot"
        case .secretFile: "secretFile"
        case .tooLarge: "tooLarge"
        case .notFound: "notFound"
        case .conflict: "conflict"
        case .alreadyExists: "alreadyExists"
        case .isDirectory: "isDirectory"
        case .unsupportedScope: "unsupportedScope"
        case .invalidPatch: "invalidPatch"
        case .invalidArguments: "invalidArguments"
        }
    }

    /// Structured envelope encoded into failed `ToolResult.outputSummary`.
    var structuredSummary: String {
        var payload: [String: String] = ["code": code]
        switch self {
        case .escapesRoot(let path), .secretFile(let path),
             .notFound(let path), .alreadyExists(let path),
             .isDirectory(let path), .unsupportedScope(let path),
             .invalidPatch(let path), .invalidArguments(let path):
            payload["detail"] = path
        case .tooLarge(let limit):
            payload["limit"] = String(limit)
        case .conflict(let expected, let actual):
            payload["expected"] = expected
            payload["actual"] = actual
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["workspaceError": payload],
            options: [.sortedKeys]
        ), let json = String(data: data, encoding: .utf8) else {
            return #"{"workspaceError":{"code":"\#(code)"}}"#
        }
        return json
    }
}
