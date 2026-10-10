// FloeTools — Capability ceiling for the workspace Canvas Agent.
//
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Builds the exact tool-name ceiling for a Canvas Agent run. The canvas is
/// a research and composition surface, never an alternate browser, terminal,
/// or unrestricted workspace agent. Native web retrieval is always bounded
/// to search/fetch. A remote MCP tool is added only after the server and the
/// individual tool are both enabled and the user explicitly grants that
/// server access to canvas runs.
public enum CanvasAgentToolPolicy {
    public static let nativeToolNames: Set<String> = [
        "web.search", "web.fetch",
        // Notes tools enforce a separate native picker grant per conversation.
        "notes.read", "notes.search", "notes.edit", "notes.attachFile", "notes.export",
        // Read-only video candidate catalog. Canvas video execution stays on
        // canvas.generate so results bind to canvas nodes; video.models lets
        // the canvas model choose a public candidate itself instead of asking
        // the user for an internal UUID.
        "video.models",
        "canvas.getState", "canvas.applyOperations", "canvas.delete",
        "canvas.assetSearch", "canvas.assetInsert", "canvas.assetImport",
        "canvas.generate", "canvas.generationStatus",
        // Design workflow tools (brief/spec/revisions/anchored feedback/
        // candidate/adopt/reject/restore). They operate on FloeCore's design
        // project model bound to canvas nodes; adopting is approval-gated.
        "canvas.designGetState", "canvas.designCapabilities",
        "canvas.designCreate", "canvas.designUpdateBrief", "canvas.designUpdateSpec",
        "canvas.designRegisterRevision", "canvas.designAddFeedback",
        "canvas.designPropose", "canvas.designAdopt", "canvas.designReject",
        "canvas.designRestore"
    ]

    public static func allowedToolNames(
        servers: [MCPServerConfiguration],
        discoveredTools: [UUID: [MCPDiscoveredTool]]
    ) -> Set<String> {
        var names = nativeToolNames
        for server in servers where server.enabled && server.allowInCanvas {
            let prefix = server.namespacePrefix + "_"
            for tool in discoveredTools[server.id] ?? []
            where !server.disabledRemoteToolNames.contains(tool.remoteName) {
                names.insert(MCPRemoteToolSource.namespacedName(
                    prefix: prefix,
                    remoteName: tool.remoteName
                ))
            }
        }
        return names
    }
}
