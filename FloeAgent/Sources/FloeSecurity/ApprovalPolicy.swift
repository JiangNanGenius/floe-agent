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
    /// A bounded, plain-text projection of the most recent conversation.
    /// This is context for the classifier only; it never becomes authority.
    public var recentContext: String
    public var hostAndPathScope: ToolScope

    public init(
        toolCall: ToolCall,
        riskLabels: Set<String>,
        userGoal: String,
        recentContext: String = "",
        hostAndPathScope: ToolScope
    ) {
        self.toolCall = toolCall
        self.riskLabels = riskLabels
        self.userGoal = String(userGoal.prefix(2048))
        self.recentContext = String(recentContext.prefix(8192))
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

/// Automatic mode: managed packages use their source-review model; when an
/// action-review model is configured, every other side-effecting action is
/// reviewed by that model. The catastrophic gate still runs first and cannot
/// be bypassed. Without a model, safe local mutations remain deterministic
/// while sensitive actions fail closed to the user.
public struct AutomaticApprovalPolicy: ApprovalPolicy {
    private let backend: (any ModelApprovalPolicy.DecisionBackend)?
    private let packageReviewBackend: (any ModelApprovalPolicy.DecisionBackend)?

    /// The runtime uses this identity to route every tool call (including
    /// read-only calls) through the configured classifier exactly once.
    public var policyName: String { backend == nil ? "automatic" : "approval-model" }

    public init(
        backend: (any ModelApprovalPolicy.DecisionBackend)? = nil,
        packageReviewBackend: (any ModelApprovalPolicy.DecisionBackend)? = nil
    ) {
        self.backend = backend
        self.packageReviewBackend = packageReviewBackend
    }

    public func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        if action.isManagedPythonPackageRequest {
            guard let packageReviewBackend else {
                return .escalateToHuman(reason: "No software package review model is configured")
            }
            do { return try await packageReviewBackend.decide(action) }
            catch {
                return .escalateToHuman(reason: "Software package review failed: \(error.localizedDescription)")
            }
        }

        if let backend {
            do { return try await backend.decide(action) }
            catch {
                // A provider outage must not make harmless reads unusable.
                // Fall back to the same deterministic local boundary used
                // when no classifier is configured; genuinely sensitive
                // actions still fail closed to the user.
                return deterministicDecision(
                    for: action,
                    unavailableReason: "Approval model unavailable: \(error.localizedDescription)"
                )
            }
        }

        return deterministicDecision(
            for: action,
            unavailableReason: "No approval model is configured for this sensitive action"
        )
    }

    private func deterministicDecision(
        for action: ProposedAction,
        unavailableReason: String
    ) -> ApprovalDecision {
        let risks = action.riskLabels
        let requiresReview: Set<String> = [
            "deletesFiles",
            "accessesCredentials",
            "modifiesRemoteSystem",
            "executesLocalCode",
            "persistsPersonalData",
            "changesAgentBehavior",
            "controlsGUI",
            "sendsDataToProvider",
            "executesRemoteCommand"
        ]
        if !risks.isDisjoint(with: requiresReview), action.toolCall.toolName != "exec.localPython" {
            return .escalateToHuman(reason: unavailableReason)
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

/// Per-task full access removes ordinary prompts for this task. The
/// catastrophic command gate still runs before this policy, and managed
/// Python package requests still receive their dedicated source review.
public struct TaskFullAccessPolicy: ApprovalPolicy {
    public let policyName = "full-access"

    private let packageReviewBackend: (any ModelApprovalPolicy.DecisionBackend)?

    public init(packageReviewBackend: (any ModelApprovalPolicy.DecisionBackend)? = nil) {
        self.packageReviewBackend = packageReviewBackend
    }

    public func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        if action.isManagedPythonPackageRequest {
            guard let packageReviewBackend else {
                return .escalateToHuman(reason: "No software package review model is configured")
            }
            do { return try await packageReviewBackend.decide(action) }
            catch {
                return .escalateToHuman(reason: "Software package review failed: \(error.localizedDescription)")
            }
        }

        return .allow(
            scope: AutomaticApprovalPolicyScope.scope(for: action.toolCall),
            expiresAt: nil
        )
    }
}

private extension ProposedAction {
    var isManagedPythonPackageRequest: Bool {
        guard toolCall.toolName == "exec.localPython",
              let object = try? JSONSerialization.jsonObject(with: toolCall.argumentsJSON) as? [String: Any],
              let packages = object["packages"] as? [Any]
        else { return false }
        return !packages.isEmpty
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
