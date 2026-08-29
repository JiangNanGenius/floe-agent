// FloeSecurity — Approval decisions and scope.
// See docs/DEVELOPMENT_PLAN.md §3.3.

import Foundation
import FloeModels

/// Secret-free authority used only while normalizing credentials emitted by a
/// provider. It binds capture to one run, one compiled tool, one approved
/// target scope, and a small set of credential fields. Capturing a secret does
/// not itself approve using it; normal tool approval remains mandatory.
public struct RunCredentialAuthority: Sendable, Codable, Identifiable, Hashable {
    public var id: UUID
    public var runID: UUID
    public var toolName: String
    public var targetScope: ToolScope
    public var allowedFieldNames: Set<String>
    public var createdAt: Date
    public var expiresAt: Date

    public init(
        id: UUID = UUID(),
        runID: UUID,
        toolName: String,
        targetScope: ToolScope,
        allowedFieldNames: Set<String> = [
            "credentialinput", "credentialref", "password", "passwd",
            "passphrase", "apikey", "api_key", "token", "secret"
        ],
        createdAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.runID = runID
        self.toolName = toolName
        self.targetScope = targetScope
        self.allowedFieldNames = allowedFieldNames
        self.createdAt = createdAt
        self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(15 * 60)
    }

    public func permits(
        toolName: String,
        targetScope: ToolScope,
        fieldPath: [String],
        at date: Date = Date()
    ) -> Bool {
        guard date < expiresAt, self.toolName == toolName,
              self.targetScope == targetScope,
              let field = fieldPath.last?.lowercased() else { return false }
        return allowedFieldNames.contains(field)
    }
}

/// What an approval covers. Intersection semantics: a grant only applies
/// when every non-nil field matches the proposed action.
public struct ApprovalScope: Sendable, Codable, Hashable {
    public var toolName: String
    public var hostID: UUID?
    /// Normalized absolute paths. Empty means no path constraint.
    public var paths: [String]
    /// Single-use grants are burned after one execution.
    public var singleUse: Bool
    /// Digest of the descriptor/runner authority approved by policy. Older
    /// checkpoints decode this as nil and may only reuse it for compiled
    /// native tools, never for replaceable dynamic sources.
    public var toolAuthorizationIdentity: String?

    public init(
        toolName: String,
        hostID: UUID? = nil,
        paths: [String] = [],
        singleUse: Bool = true,
        toolAuthorizationIdentity: String? = nil
    ) {
        self.toolName = toolName
        self.hostID = hostID
        self.paths = paths
        self.singleUse = singleUse
        self.toolAuthorizationIdentity = toolAuthorizationIdentity
    }
}

/// Outcome of a policy decision.
public enum ApprovalDecision: Sendable, Codable, Hashable {
    case allow(scope: ApprovalScope, expiresAt: Date?)
    case deny(reason: String)
    case escalateToHuman(reason: String)
    /// Catastrophic-action gate stopped the action. Release requires a
    /// second local authentication plus impact confirmation.
    case stopped(gateReason: String)

    /// True when this decision permits execution right now.
    public var permitsExecution: Bool {
        if case .allow = self { return true }
        return false
    }

    /// Stable machine label for logs — never carries a reason (which may be
    /// sensitive); only the decision branch.
    public var logLabel: String {
        switch self {
        case .allow: return "allow"
        case .deny: return "deny"
        case .escalateToHuman: return "escalateToHuman"
        case .stopped: return "stopped"
        }
    }
}

/// A persisted grant derived from an `.allow` decision.
public struct ApprovalGrant: Sendable, Codable, Identifiable, Hashable {
    public var id: UUID
    public var scope: ApprovalScope
    public var expiresAt: Date?
    public var decidedAt: Date
    /// Which policy produced this grant (audit trail).
    public var policyName: String

    public init(
        id: UUID = UUID(),
        scope: ApprovalScope,
        expiresAt: Date?,
        decidedAt: Date = Date(),
        policyName: String
    ) {
        self.id = id
        self.scope = scope
        self.expiresAt = expiresAt
        self.decidedAt = decidedAt
        self.policyName = policyName
    }

    public func isExpired(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }
}
