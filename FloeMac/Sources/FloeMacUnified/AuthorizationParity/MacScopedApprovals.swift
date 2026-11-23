// SPDX-License-Identifier: MPL-2.0
//
// Composition helpers between the connector service and the scoped
// tool/session grants. No global mutable state and no parallel authority:
// the coordinator builds an immutable binding map from the tools offered
// to a run, hands one copy to `MacScopedToolGrantPolicy` and uses the same
// bindings to record grants inside `resolveApproval`'s accepted branch.

/// Builds the immutable per-run binding map from the connector service's
/// advertised tools. Called on the main actor at run composition; the
/// result is handed to `MacScopedToolGrantPolicy` verbatim. Tools whose
/// binding is unavailable (already retired) are simply absent, so every
/// scoped check for them fails closed.
@MainActor
public func MacWorkbenchConnectorBindings(
    from connectors: MacWorkbenchConnectorsService
) -> [String: MacWorkbenchConnectorToolBinding] {
    var map: [String: MacWorkbenchConnectorToolBinding] = [:]
    for tool in connectors.publishedTools {
        guard let binding = connectors.binding(for: tool.descriptor.name) else { continue }
        map[tool.descriptor.name] = binding
    }
    return map
}

enum MacScopedApprovals {
    /// Records the chosen tool/session grant after the host accepted the
    /// exact, currently pending approval receipt. The `binding` is the exact
    /// immutable value captured for the run (or re-resolved from the
    /// connector service in the accepted branch); recording uses its
    /// digests and the approved call's argument digest only — raw arguments
    /// and credential values never enter the grant store. Errors propagate
    /// so the accepted branch can surface a grant failure honestly.
    static func record(approval: HostAgentApproval, scope: MacScopedApprovalScope,
                       binding: MacWorkbenchConnectorToolBinding) async throws {
        let argumentsDigest = MacWorkbenchConnectorToolBinding.argumentsDigest(approval.toolCall.argumentsJSON)
        switch scope {
        case .toolTask:
            try await MacScopedToolGrants.shared.remember(
                scope: .task, workspaceID: approval.workspaceID,
                conversationID: approval.conversationID, toolName: approval.toolName,
                descriptorIdentity: binding.descriptorIdentity,
                endpointDigest: binding.endpointDigest,
                authenticationDigest: binding.authenticationDigest,
                argumentsDigest: argumentsDigest)
        case .toolProject:
            try await MacScopedToolGrants.shared.remember(
                scope: .project, workspaceID: approval.workspaceID,
                conversationID: approval.conversationID, toolName: approval.toolName,
                descriptorIdentity: binding.descriptorIdentity,
                endpointDigest: binding.endpointDigest,
                authenticationDigest: binding.authenticationDigest,
                argumentsDigest: argumentsDigest)
        case .toolSession:
            await MacSessionApprovalGrants.shared.remember(
                workspaceID: approval.workspaceID, conversationID: approval.conversationID,
                toolName: approval.toolName,
                descriptorIdentity: binding.descriptorIdentity,
                endpointDigest: binding.endpointDigest,
                authenticationDigest: binding.authenticationDigest,
                argumentsDigest: argumentsDigest)
        }
    }

    /// Revokes every persisted and session grant for one tool name. The
    /// coordinator calls this when a connector server is disabled or
    /// removed, so stale authority cannot survive the tool's teardown.
    /// Matching is fail-closed regardless: retired bindings never satisfy
    /// a grant check.
    static func revokeAll(toolName: String) async {
        try? await MacScopedToolGrants.shared.revokeAll(toolName: toolName)
        await MacSessionApprovalGrants.shared.revokeAll(toolName: toolName)
    }
}
