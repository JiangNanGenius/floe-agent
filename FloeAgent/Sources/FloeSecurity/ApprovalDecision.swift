// FloeSecurity — Approval decisions and scope.
// See docs/DEVELOPMENT_PLAN.md §3.3.

import Foundation

/// What an approval covers. Intersection semantics: a grant only applies
/// when every non-nil field matches the proposed action.
public struct ApprovalScope: Sendable, Codable, Hashable {
    public var toolName: String
    public var hostID: UUID?
    /// Normalized absolute paths. Empty means no path constraint.
    public var paths: [String]
    /// Single-use grants are burned after one execution.
    public var singleUse: Bool

    public init(toolName: String, hostID: UUID? = nil, paths: [String] = [], singleUse: Bool = true) {
        self.toolName = toolName
        self.hostID = hostID
        self.paths = paths
        self.singleUse = singleUse
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
