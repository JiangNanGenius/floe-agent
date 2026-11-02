// SPDX-License-Identifier: MPL-2.0
//
// C08 B0 — model workspace-file tool relink (App side).
//
// WHAT THIS CLOSES
// The Android FloeWorkspace mirror deliberately carried only
// `WorkspaceToolEnvironment`/`WorkspaceToolSupport`; the original model-facing
// file tools (listDirectory/readFile/searchFiles/inspectFileMetadata/
// writeFile/applyPatch/createFile/moveFile/deleteFile/copyFile/appendFile/
// replaceText/createDirectory) were never reachable from a run. This file is
// the registration seam that binds those ORIGINAL tools (restored by the
// bounded Main patch beside this package) to the EXISTING
// `WorkspaceFileService`/`WorkspacePathGuard` authority:
//
//   * every call resolves the run's trusted `ToolContext.workspaceRootURL`
//     (the per-task binding assembled by `RuntimeFacadeRunAssembly` from the
//     ORIGINAL conversation/workspace rows through
//     `LinuxWorkspaceAuthority.trustedWorkspaceRoot`). There is no UI-global
//     root, no first-project choice and no temporary-directory fallback: with
//     no context root the tool fails structured (`notFound("workspace ...")`).
//   * the existing path guard still rejects empty/absolute/traversal/symlink
//     paths, secret files and size caps; `context.authorizeWorkspacePath`
//     still applies the task's declared path ceiling first.
//   * the existing write path still holds `WorkspaceMutationLocks`, uses
//     digest/mtime CAS, leaves failed patches untouched and runs the design
//     freeze mutation gate.
//   * `scope` arguments may only be `"local"` and a host/hostPath ToolScope is
//     refused exactly as the ORIGINAL tool bodies require. App-authorized
//     imported/document workspace data is therefore never presented as an
//     operation on a selected remote SSH/Linux target: remote file work stays
//     with the existing SFTP/remote tools, while the task Linux guest sees the
//     SAME Core task workspace only through the separately owned C01
//     workspace-exchange producer.
//   * temporary (ephemeral) chats are outside the ceiling twice: the original
//     `TemporaryChatToolPolicy` removes these names from the offered set and
//     `WorkspaceToolEnvironment.rootURL(context:)` refuses a temporary context
//     before any file effect.
//
// DISCOVERY IS THE REGISTRY'S REAL SURFACE
// `ToolRunnerRegistry.allDescriptors` is the executable,
// availability-filtered descriptor set consumed by `CatalogToolExecutor`;
// `ToolCatalog` entries remain documentation. Availability here is a live
// accepted native generation (`G02NativeRootEpoch.readback() != nil`), so a
// retired/uninstalled generation advertises nothing, and the per-run workspace
// root remains a per-call check (a generation can be live while a particular
// temporary/Notes run has no task workspace). Tests inject a deterministic
// availability closure; production uses the default.
//
// APPEND/REPLACE SURFACE DELTA (explicit)
// The iOS donor registers `workspace.appendFile` and `workspace.replaceText`
// with `compatibilityOnly: true`, which hides them from `allDescriptors`.
// This package exposes those SAME original names/schemas as ordinary
// discoverable tools because the accepted C08 scope enumerates them as model
// file tools. Nothing new is defined: both are the original tool bodies over
// the original read/modify/write CAS path. No alias or duplicate service is
// introduced.
//
// NO PARALLEL ARCHITECTURE
// No new store, permission table, workspace root or path resolver exists here.
// This is composition over FloeWorkspace's public environment + the existing
// FloeTools catalog/registry.

import Foundation
import FloeCore
import FloeTools
import FloeWorkspace

public enum C08WorkspaceFileTools {
    /// The exact ORIGINAL canonical names bound by this seam. `workspace
    /// .createDirectory` is included because it is part of the same original
    /// file-domain surface and is required by the original registration.
    public static let toolNames: [String] = [
        "workspace.listDirectory",
        "workspace.readFile",
        "workspace.searchFiles",
        "workspace.inspectFileMetadata",
        "workspace.createFile",
        "workspace.appendFile",
        "workspace.replaceText",
        "workspace.writeFile",
        "workspace.applyPatch",
        "workspace.moveFile",
        "workspace.deleteFile",
        "workspace.createDirectory",
        "workspace.copyFile",
    ]

    /// Registers the original catalog descriptors and REAL runners.
    ///
    /// - Parameters:
    ///   - registry: The runner registry the current run composition reads
    ///     (defaults to the process-wide registry used by
    ///     `CatalogToolExecutor`).
    ///   - isAvailable: Executable-discovery gate. The production default
    ///     requires an accepted live native root epoch; tests and host
    ///     fixtures inject their own deterministic value. It is never derived
    ///     from model text.
    /// - Returns: The shared tool environment (rootless by design; every call
    ///   must carry `ToolContext.workspaceRootURL`).
    @discardableResult
    public static func install(
        into registry: ToolRunnerRegistry = .shared,
        isAvailable: @escaping @Sendable () -> Bool = { G02NativeRootEpoch.readback() != nil }
    ) -> WorkspaceToolEnvironment {
        // Rootless on purpose: `WorkspaceToolEnvironment.rootURL(context:)`
        // prefers the trusted per-run context root and, with no provider,
        // fails closed instead of falling back to an App/UI workspace.
        let environment = WorkspaceToolEnvironment(rootProvider: { nil })

        ToolCatalog.register(WorkspaceListDirectoryTool.self)
        ToolCatalog.register(WorkspaceReadFileTool.self)
        ToolCatalog.register(WorkspaceSearchFilesTool.self)
        ToolCatalog.register(WorkspaceInspectMetadataTool.self)
        ToolCatalog.register(WorkspaceCreateFileTool.self)
        ToolCatalog.register(WorkspaceAppendFileTool.self)
        ToolCatalog.register(WorkspaceReplaceTextTool.self)
        ToolCatalog.register(WorkspaceWriteFileTool.self)
        ToolCatalog.register(WorkspaceApplyPatchTool.self)
        ToolCatalog.register(WorkspaceMoveFileTool.self)
        ToolCatalog.register(WorkspaceDeleteFileTool.self)
        ToolCatalog.register(WorkspaceCreateDirectoryTool.self)
        ToolCatalog.register(WorkspaceCopyFileTool.self)

        register(WorkspaceListDirectoryTool(environment: environment),
                 isAvailable: isAvailable, into: registry)
        register(WorkspaceReadFileTool(environment: environment),
                 isAvailable: isAvailable, into: registry)
        register(WorkspaceSearchFilesTool(environment: environment),
                 isAvailable: isAvailable, into: registry)
        register(WorkspaceInspectMetadataTool(environment: environment),
                 isAvailable: isAvailable, into: registry)
        register(WorkspaceCreateFileTool(environment: environment),
                 isAvailable: isAvailable, into: registry)
        register(WorkspaceAppendFileTool(environment: environment),
                 isAvailable: isAvailable, into: registry)
        register(WorkspaceReplaceTextTool(environment: environment),
                 isAvailable: isAvailable, into: registry)
        register(WorkspaceWriteFileTool(environment: environment),
                 isAvailable: isAvailable, into: registry)
        register(WorkspaceApplyPatchTool(environment: environment),
                 isAvailable: isAvailable, into: registry)
        register(WorkspaceMoveFileTool(environment: environment),
                 isAvailable: isAvailable, into: registry)
        register(WorkspaceDeleteFileTool(environment: environment),
                 isAvailable: isAvailable, into: registry)
        register(WorkspaceCreateDirectoryTool(environment: environment),
                 isAvailable: isAvailable, into: registry)
        register(WorkspaceCopyFileTool(environment: environment),
                 isAvailable: isAvailable, into: registry)

        return environment
    }

    /// Recognizes whether `name` belongs to the file-domain surface this seam
    /// owns. Used by callers that need an honest capability explanation
    /// without duplicating the name list.
    public static func owns(toolName: String) -> Bool {
        toolNames.contains(toolName)
    }

    private static func register<T: AgentTool>(
        _ tool: T,
        isAvailable: @escaping @Sendable () -> Bool,
        into registry: ToolRunnerRegistry
    ) {
        var runner = AnyAgentTool(tool)
        runner.isAvailable = isAvailable
        registry.register(runner)
    }
}
