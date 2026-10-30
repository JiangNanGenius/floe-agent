import Foundation

/// Versioned host dependency exclusions. These directories remain managed by
/// the Mac toolchain; source files and user-facing build products still sync.
/// This manifest is code-owned and cannot grant file access or run commands.
public enum BridgeWorkspaceTransferPolicy {
    public static let version = 2
    public static let hostDependencyDirectories: Set<String> = [
        "node_modules", ".venv", ".floe-env", ".floe-node", "__pycache__", ".build", ".pytest_cache", ".mypy_cache", ".ruff_cache"
    ]
    public static func excludes(_ relative: String) -> Bool {
        let components = relative.split(separator: "/").map(String.init)
        return components.contains(where: hostDependencyDirectories.contains)
            || [".floe/terminal", ".floe/remote-sync", ".floe/migrations"].contains(where: { relative == $0 || relative.hasPrefix($0 + "/") })
    }
}
