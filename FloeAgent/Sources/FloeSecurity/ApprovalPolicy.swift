// FloeSecurity — Approval policy contracts and implementations.
// See docs/DEVELOPMENT_PLAN.md §3.3.

import Foundation
import FloeCore
import FloeModels

/// A fully-described action presented to a policy for decision.
public struct ProposedAction: Sendable, Codable {
    public var toolCall: ToolCall
    /// Deterministic labels from the tool catalog — never model-derived.
    public var riskLabels: Set<String>
    /// The user's original goal, truncated to 2 KiB.
    public var userGoal: String
    public var hostAndPathScope: ToolScope

    public init(toolCall: ToolCall, riskLabels: Set<String>, userGoal: String, hostAndPathScope: ToolScope) {
        self.toolCall = toolCall
        self.riskLabels = riskLabels
        self.userGoal = String(userGoal.prefix(2048))
        self.hostAndPathScope = hostAndPathScope
    }
}

/// Decision-making strategy. All side-effecting actions pass through the
/// catastrophic gate first, then through exactly one policy.
public protocol ApprovalPolicy: Sendable {
    var policyName: String { get }
    func decide(_ action: ProposedAction) async throws -> ApprovalDecision
}

/// Policy 1: every side-effecting action waits for the user.
public struct HumanApprovalPolicy: ApprovalPolicy {
    public let policyName = "human"

    public init() {}

    public func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        .escalateToHuman(reason: "Human approval policy requires explicit user decision")
    }
}

/// Policy 2: a configured model returns allow / deny / escalate.
/// The approval model receives the goal, structured action, scope, and
/// deterministic risk labels. It has no tool channel and cannot rewrite
/// the tool call. Any failure is fail-closed (escalate).
public struct ModelApprovalPolicy: ApprovalPolicy {
    public let policyName = "approval-model"

    /// Abstraction over the approval model call so this type stays
    /// testable without a live provider.
    public protocol DecisionBackend: Sendable {
        func decide(_ action: ProposedAction) async throws -> ApprovalDecision
    }

    private let backend: any DecisionBackend

    public init(backend: any DecisionBackend) {
        self.backend = backend
    }

    public func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        do {
            return try await backend.decide(action)
        } catch {
            return .escalateToHuman(reason: "Approval model failed: \(error.localizedDescription)")
        }
    }
}

/// Policy 3: full control for one host within a time window.
/// Enabling requires Face ID or passcode plus a risk acknowledgement
/// (handled by the UI layer before constructing the grant).
public struct FullControlPolicy: ApprovalPolicy {
    public let policyName = "full-control"

    public struct Grant: Sendable, Codable, Hashable {
        public var hostID: UUID
        public var expiresAt: Date?

        public init(hostID: UUID, expiresAt: Date?) {
            self.hostID = hostID
            self.expiresAt = expiresAt
        }

        public func isActive(at now: Date = Date()) -> Bool {
            guard let expiresAt else { return true } // until connection closes
            return now < expiresAt
        }
    }

    private let grant: Grant

    public init(grant: Grant) {
        self.grant = grant
    }

    public func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        guard grant.isActive() else {
            return .escalateToHuman(reason: "Full-control window expired")
        }
        switch action.hostAndPathScope {
        case .host(let id) where id == grant.hostID,
             .hostPath(let id, _) where id == grant.hostID:
            return .allow(
                scope: ApprovalScope(
                    toolName: action.toolCall.toolName,
                    hostID: grant.hostID,
                    singleUse: true
                ),
                expiresAt: grant.expiresAt
            )
        case .host, .hostPath:
            return .escalateToHuman(reason: "Action targets a host outside the full-control grant")
        case .local:
            // Local non-destructive actions still flow; the gate already ran.
            return .allow(
                scope: ApprovalScope(toolName: action.toolCall.toolName, singleUse: true),
                expiresAt: grant.expiresAt
            )
        }
    }
}
