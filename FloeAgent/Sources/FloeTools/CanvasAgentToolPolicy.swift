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
        "canvas.inspect", "canvas.applyPatch",
        "canvas.assetSearch", "canvas.assetInsert",
        "canvas.generateMedia", "canvas.mediaStatus"
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
