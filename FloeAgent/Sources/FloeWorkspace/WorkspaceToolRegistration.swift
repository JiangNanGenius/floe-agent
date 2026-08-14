// FloeWorkspace — Tool registration entry point.
// See docs/ARCHITECTURE_AGENT_WORKSPACE.md §6 接线: called once at app
// startup from `AppEnvironment`. Registers the nine workspace tool
// descriptors with `ToolCatalog` (compile-time visibility) and the matching
// `AnyAgentTool` runners with `ToolRunnerRegistry` (runtime execution).
// Both are required for a tool to execute. The runtime module never
// imports FloeWorkspace; decoupling flows through the registry.

import Foundation
import FloeCore
import FloeTools

/// Registers all nine workspace file tools.
///
/// - Parameters:
///   - rootProvider: Supplies the current workspace root URL. Returning nil
///     means no workspace is open; tools then fail with a structured
///     `notFound` instead of crashing. T05 wires this to WorkspaceCenter.
///   - registry: Runner registry to register into (defaults to the shared
///     process-wide registry used by `CatalogToolExecutor`).
/// - Returns: The shared environment handed to every tool, so callers can
///   re-point the root provider if needed.
@discardableResult
public func registerWorkspaceTools(
    rootProvider: @escaping @Sendable () -> URL?,
    registry: ToolRunnerRegistry = .shared
) -> WorkspaceToolEnvironment {
    let environment = WorkspaceToolEnvironment(rootProvider: rootProvider)

    // Compile-time catalog descriptors.
    ToolCatalog.register(WorkspaceListDirectoryTool.self)
    ToolCatalog.register(WorkspaceReadFileTool.self)
    ToolCatalog.register(WorkspaceSearchFilesTool.self)
    ToolCatalog.register(WorkspaceInspectMetadataTool.self)
    ToolCatalog.register(WorkspaceCreateFileTool.self)
    ToolCatalog.register(WorkspaceWriteFileTool.self)
    ToolCatalog.register(WorkspaceApplyPatchTool.self)
    ToolCatalog.register(WorkspaceMoveFileTool.self)
    ToolCatalog.register(WorkspaceDeleteFileTool.self)

    // Runtime runners.
    registry.register(WorkspaceListDirectoryTool(environment: environment))
    registry.register(WorkspaceReadFileTool(environment: environment))
    registry.register(WorkspaceSearchFilesTool(environment: environment))
    registry.register(WorkspaceInspectMetadataTool(environment: environment))
    registry.register(WorkspaceCreateFileTool(environment: environment))
    registry.register(WorkspaceWriteFileTool(environment: environment))
    registry.register(WorkspaceApplyPatchTool(environment: environment))
    registry.register(WorkspaceMoveFileTool(environment: environment))
    registry.register(WorkspaceDeleteFileTool(environment: environment))

    return environment
}
