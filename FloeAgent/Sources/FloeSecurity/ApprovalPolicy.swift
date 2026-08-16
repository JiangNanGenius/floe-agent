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

/// Three-tier automatic mode: deterministic low-risk actions are allowed,
/// sensitive actions always return to the user, and only the ambiguous
/// middle tier may be delegated to a configured, tool-free approval model.
public struct AutomaticApprovalPolicy: ApprovalPolicy {
    public let policyName = "automatic"
    private let backend: (any ModelApprovalPolicy.DecisionBackend)?

    public init(backend: (any ModelApprovalPolicy.DecisionBackend)? = nil) {
        self.backend = backend
    }

    public func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        let risks = action.riskLabels
        let alwaysAsk: Set<String> = [
            "deletesFiles",
            "accessesCredentials",
            "modifiesRemoteSystem"
        ]
        if !risks.isDisjoint(with: alwaysAsk) {
            return .escalateToHuman(reason: "Sensitive action requires explicit approval")
        }

        let ambiguous: Set<String> = [
            "controlsGUI",
            "sendsDataToProvider",
            "executesRemoteCommand"
        ]
        if !risks.isDisjoint(with: ambiguous) {
            guard let backend else {
                return .escalateToHuman(reason: "No approval model is configured for this medium-risk action")
            }
            do {
                return try await backend.decide(action)
            } catch {
                return .escalateToHuman(reason: "Approval model unavailable: \(error.localizedDescription)")
            }
        }
        return .allow(
            scope: Self.scope(for: action.toolCall),
            expiresAt: nil
        )
    }

    private static func scope(for call: ToolCall) -> ApprovalScope {
        switch call.scope {
        case .local:
            ApprovalScope(toolName: call.toolName, singleUse: true)
        case .host(let hostID):
            ApprovalScope(toolName: call.toolName, hostID: hostID, singleUse: true)
        case .hostPath(let hostID, let path):
            ApprovalScope(
                toolName: call.toolName,
                hostID: hostID,
                paths: [path],
                singleUse: true
            )
        }
    }
}

/// Per-task full access removes ordinary prompts, but does not turn deletion,
/// credential access or data upload into ambient authority. Those categories
/// remain explicit single-action decisions in every user-facing mode.
public struct TaskFullAccessPolicy: ApprovalPolicy {
    public let policyName = "full-access"

    public init() {}

    public func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        let alwaysAsk: Set<String> = [
            "deletesFiles",
            "accessesCredentials",
            "sendsDataToProvider"
        ]
        if !action.riskLabels.isDisjoint(with: alwaysAsk) {
            return .escalateToHuman(reason: "This sensitive action always requires explicit approval")
        }
        return .allow(
            scope: AutomaticApprovalPolicyScope.scope(for: action.toolCall),
            expiresAt: nil
        )
    }
}

private enum AutomaticApprovalPolicyScope {
    static func scope(for call: ToolCall) -> ApprovalScope {
        switch call.scope {
        case .local:
            ApprovalScope(toolName: call.toolName, singleUse: true)
        case .host(let hostID):
            ApprovalScope(toolName: call.toolName, hostID: hostID, singleUse: true)
        case .hostPath(let hostID, let path):
            ApprovalScope(toolName: call.toolName, hostID: hostID, paths: [path], singleUse: true)
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
