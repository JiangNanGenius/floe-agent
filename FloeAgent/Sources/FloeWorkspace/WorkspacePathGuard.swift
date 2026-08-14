// FloeWorkspace — Placeholder for T04 (path guard + file tools).
// See docs/ARCHITECTURE_AGENT_WORKSPACE.md §3/§6. This target ships in
// T04; T01 only declares the module so it compiles.

import Foundation

/// Namespace marker for the FloeWorkspace module. Real types
/// (`WorkspacePathGuard`, `WorkspaceFileService`, workspace file tools)
/// land in T04.
public enum FloeWorkspaceModule {
    /// Module version marker; replaced by real API in T04.
    public static let placeholder = "T04"
}
