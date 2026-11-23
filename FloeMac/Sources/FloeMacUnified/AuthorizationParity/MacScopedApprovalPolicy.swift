// SPDX-License-Identifier: MPL-2.0
//
// Session-scoped tool approvals and the scoped-grant approval policy for the
// Floe Mac workbench.
//
// Session grants are process-lifetime approvals ("remember for this
// session") backed by the SHARED in-memory `ApprovalGrantStore`
// (FloeSecurity) — the same store family the iPad settings surface lists as
// session grants. Like persisted tool grants they bind the exact tool name,
// descriptor identity, endpoint digest, authentication digest and the
// SHA-256 of the exact approved call arguments, AND the current workspace
// and conversation: a session grant never applies to a different task.
//
// `MacScopedToolGrantPolicy` is the consumption point: it wraps the run's
// ordinary approval policy and can only upgrade a HUMAN escalation in Ask
// mode into an allow on an exact binding match. Automatic/full-access
// policies stay fully authoritative, the catastrophic action gate still
// runs first, and subagents inherit the run policy like every other
// decision. The wrapper composes inside the existing Mac native/file/memory
// policy stack (it sits directly around the base human policy).

import Foundation
import FloeCore
import FloeModels
import FloeSecurity

// MARK: - Session grants

/// Display model for one session-scoped approval.
public struct MacSessionToolGrant: Identifiable, Sendable {
    public let id: UUID
    public let workspaceID: UUID
    public let conversationID: UUID
    public let toolName: String
    public let argumentsDigest: String
    public let decidedAt: Date

    public init(id: UUID, workspaceID: UUID, conversationID: UUID, toolName: String,
                argumentsDigest: String, decidedAt: Date) {
        self.id = id
        self.workspaceID = workspaceID
        self.conversationID = conversationID
        self.toolName = toolName
        self.argumentsDigest = argumentsDigest
        self.decidedAt = decidedAt
    }
}

/// Process-lifetime tool approvals scoped to one workspace + conversation.
/// One shared store backs both the approval policy consultation and the
/// settings listing, so revocation is immediate for every run in this
/// process. The narrow binding lives in `ApprovalScope.paths` as opaque
/// tokens (never raw arguments), so the shared store keeps owning expiry,
/// revocation and claiming.
public actor MacSessionApprovalGrants {
    /// Shared store for the app composition root; focused tests create their
    /// own instance. The coordinator may inject the same instance into the
    /// run policy so listings and decisions never diverge.
    public static let shared = MacSessionApprovalGrants()

    private let store: ApprovalGrantStore

    public init(store: ApprovalGrantStore = ApprovalGrantStore()) {
        self.store = store
    }

    /// The underlying shared store (for policy wiring by the coordinator).
    public nonisolated var grantStore: ApprovalGrantStore { store }

    static func bindingTokens(workspaceID: UUID, conversationID: UUID,
                              endpointDigest: String, authenticationDigest: String,
                              argumentsDigest: String) -> [String] {
        ["ws:\(workspaceID.uuidString)", "conv:\(conversationID.uuidString)",
         "endpoint:\(endpointDigest)", "auth:\(authenticationDigest)", "args:\(argumentsDigest)"]
    }

    static func tokens(from paths: [String]) -> (workspaceID: UUID, conversationID: UUID,
                                                 endpointDigest: String, authenticationDigest: String,
                                                 argumentsDigest: String)? {
        var values: [String: String] = [:]
        for path in paths {
            let parts = path.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            values[String(parts[0])] = String(parts[1])
        }
        guard let workspaceID = values["ws"].flatMap(UUID.init(uuidString:)),
              let conversationID = values["conv"].flatMap(UUID.init(uuidString:)),
              let endpoint = values["endpoint"], !endpoint.isEmpty,
              let auth = values["auth"], !auth.isEmpty,
              let args = values["args"], !args.isEmpty else { return nil }
        return (workspaceID, conversationID, endpoint, auth, args)
    }

    public func remember(workspaceID: UUID, conversationID: UUID, toolName: String,
                         descriptorIdentity: String, endpointDigest: String,
                         authenticationDigest: String, argumentsDigest: String) async {
        guard MacScopedToolGrants.canRemember(toolName: toolName), !descriptorIdentity.isEmpty else { return }
        await store.add(ApprovalGrant(
            scope: ApprovalScope(
                toolName: toolName,
                paths: Self.bindingTokens(workspaceID: workspaceID,
                                          conversationID: conversationID,
                                          endpointDigest: endpointDigest,
                                          authenticationDigest: authenticationDigest,
                                          argumentsDigest: argumentsDigest),
                singleUse: false,
                toolAuthorizationIdentity: descriptorIdentity
            ),
            expiresAt: nil,
            policyName: "floe.mac.session-tool-grant"
        ))
    }

    public func all() async -> [MacSessionToolGrant] {
        await store.allGrants.compactMap { grant in
            guard !grant.isExpired(), !grant.scope.singleUse,
                  let decoded = Self.tokens(from: grant.scope.paths) else { return nil }
            return MacSessionToolGrant(id: grant.id, workspaceID: decoded.workspaceID,
                                       conversationID: decoded.conversationID,
                                       toolName: grant.scope.toolName,
                                       argumentsDigest: decoded.argumentsDigest,
                                       decidedAt: grant.decidedAt)
        }
        .sorted { $0.decidedAt > $1.decidedAt }
    }

    public func revoke(id: UUID) async {
        await store.revoke(id: id)
    }

    public func revokeAll(toolName: String) async {
        let ids = await store.allGrants
            .filter { $0.scope.toolName == toolName && $0.policyName == "floe.mac.session-tool-grant" }
            .map(\.id)
        for id in ids { await store.revoke(id: id) }
    }

    /// Revoke every session grant in one server's exact id-derived
    /// namespace, whatever task wrote it.
    public func revokeAll(toolNamePrefix: String) async {
        let ids = await store.allGrants
            .filter { $0.scope.toolName.hasPrefix(toolNamePrefix) }
            .map(\.id)
        for id in ids { await store.revoke(id: id) }
    }

    /// True when a live session grant covers the EXACT binding for this
    /// workspace + conversation + tool + descriptor identity + endpoint +
    /// authentication + arguments digest.
    public func matches(workspaceID: UUID, conversationID: UUID, toolName: String,
                        descriptorIdentity: String, endpointDigest: String,
                        authenticationDigest: String, argumentsDigest: String) async -> Bool {
        guard !descriptorIdentity.isEmpty else { return false }
        let expected = Set(Self.bindingTokens(workspaceID: workspaceID, conversationID: conversationID,
                                              endpointDigest: endpointDigest,
                                              authenticationDigest: authenticationDigest,
                                              argumentsDigest: argumentsDigest))
        let live = await store.allGrants.filter {
            !$0.isExpired() && !$0.scope.singleUse && $0.scope.toolName == toolName
                && $0.scope.hostID == nil
                && $0.scope.toolAuthorizationIdentity == descriptorIdentity
                && Set($0.scope.paths) == expected
        }
        return !live.isEmpty
    }
}

// MARK: - Scope picker model

/// The remember choice offered on an approval card for a rememberable tool.
public enum MacScopedApprovalScope: Sendable, Hashable {
    /// Persisted for this task only.
    case toolTask
    /// Persisted for the whole project workspace.
    case toolProject
    /// Process-lifetime session grant for this workspace + conversation.
    case toolSession
}

// MARK: - Policy

/// Wraps the run's base approval policy with persisted tool grants and
/// session tool grants. It composes INSIDE the existing Mac policy stack —
/// typically directly around the base human policy, with the file-grant,
/// native-command and memory wrappers outside.
///
/// Semantics: the base policy decides first; only a HUMAN escalation
/// (`escalateToHuman`) in Ask mode can be upgraded, and only on an exact
/// binding match for local actions: tool name, descriptor identity,
/// endpoint digest, authentication digest, arguments digest, workspace and
/// task (or project-wide persisted grant). Nothing here bypasses the
/// catastrophic gate or weakens automatic/full-access policies.
///
/// The accepted bindings are an IMMUTABLE snapshot built from the tools
/// offered to the run. When the connector service retires a tool its
/// binding leaves the snapshot, so every scoped check fails closed.
public struct MacScopedToolGrantPolicy: ApprovalPolicy, ApprovalReviewRouting {
    let base: any ApprovalPolicy
    let grants: MacScopedToolGrants
    let session: MacSessionApprovalGrants
    let workspaceID: UUID
    let conversationID: UUID
    /// Exact binding per offered tool name, captured at composition time.
    let bindings: [String: MacWorkbenchConnectorToolBinding]
    /// True only for Ask mode (the human policy). The coordinator passes
    /// `mode == .ask`; automatic/full-access modes never consult grants.
    let askModeOnly: Bool

    public init(base: any ApprovalPolicy, grants: MacScopedToolGrants,
                session: MacSessionApprovalGrants, workspaceID: UUID,
                conversationID: UUID,
                bindings: [String: MacWorkbenchConnectorToolBinding],
                askModeOnly: Bool) {
        self.base = base
        self.grants = grants
        self.session = session
        self.workspaceID = workspaceID
        self.conversationID = conversationID
        self.bindings = bindings
        self.askModeOnly = askModeOnly
    }

    public var policyName: String { base.policyName }

    public func requiresModelReview(_ action: ProposedAction) -> Bool {
        (base as? any ApprovalReviewRouting)?.requiresModelReview(action) ?? false
    }

    public func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        let decision = try await base.decide(action)
        guard askModeOnly, case .escalateToHuman = decision else { return decision }
        // Native process boundary: only local actions can consume a local
        // tool grant, exactly like the file-grant rules.
        guard case .local = action.toolCall.scope, case .local = action.hostAndPathScope else { return decision }
        let toolName = action.toolCall.toolName
        // Fail closed: no binding offered for this tool (retired, disabled
        // or never published) — the escalation stands.
        guard MacScopedToolGrants.canRemember(toolName: toolName), let binding = bindings[toolName] else { return decision }
        let argumentsDigest = MacWorkbenchConnectorToolBinding.argumentsDigest(action.toolCall.argumentsJSON)
        if try await grants.matches(toolName: toolName, workspaceID: workspaceID,
                                    conversationID: conversationID,
                                    descriptorIdentity: binding.descriptorIdentity,
                                    endpointDigest: binding.endpointDigest,
                                    authenticationDigest: binding.authenticationDigest,
                                    argumentsDigest: argumentsDigest) {
            return .allow(scope: ApprovalScope(toolName: toolName, singleUse: true), expiresAt: nil)
        }
        if await session.matches(workspaceID: workspaceID, conversationID: conversationID,
                                 toolName: toolName,
                                 descriptorIdentity: binding.descriptorIdentity,
                                 endpointDigest: binding.endpointDigest,
                                 authenticationDigest: binding.authenticationDigest,
                                 argumentsDigest: argumentsDigest) {
            return .allow(scope: ApprovalScope(toolName: toolName, singleUse: true), expiresAt: nil)
        }
        return decision
    }
}
