import Foundation
import FloeModels
import FloeTools

public enum PlanToolDenialReason: String, Sendable, Codable, Hashable {
    case mutationNotAllowed
    case internalStateNotModelCallable
    case unknownTool
}

/// Capability filter used both while constructing provider schemas and
/// immediately before execution. It is deliberately independent of model
/// instructions: a forged tool call still reaches `decision(for:)`.
/// Native questions, the exact main-run checklist reset and the exact
/// durable-memory writes are narrow internal-state exceptions. None grants
/// external mutation authority, and each is matched by its full descriptor
/// identity (name, effect, side-effect flag, risk set and boundary).
public struct PlanToolPolicy: Sendable {
    public init() {}

    /// The only internal-state writes Plan may perform (see `decision`).
    static let memoryWriteNames: Set<String> = [
        "memory.remember", "memory.update", "memory.forget",
    ]

    public func decision(for descriptor: ToolCatalog.Descriptor) -> Result<Void, PlanToolPolicyError> {
        // Durable-memory writes are the one internal-state family Plan may
        // exercise, and only with their EXACT registered identity: an
        // internal-state, side-effecting descriptor whose only risk is
        // persisted personal data, runnable in any run and requiring no host
        // scope. This mirrors the latest iOS `ConversationToolAccess`/policy
        // (Plan inherits the chat memory names); a changed tool name, effect,
        // risk set, boundary or scope loses the exception. Memory tools still
        // need a real registered store at runtime — this only removes the
        // blanket Plan denial, it never registers or fabricates a capability.
        if Self.memoryWriteNames.contains(descriptor.name) {
            guard descriptor.effect == .internalState,
                  descriptor.isSideEffecting,
                  descriptor.riskLabels == [.persistsPersonalData],
                  descriptor.executionBoundary == .any,
                  !descriptor.requiresHostScope else {
                return .failure(PlanToolPolicyError(reason: .mutationNotAllowed, toolName: descriptor.name))
            }
            return .success(())
        }
        switch descriptor.effect {
        case .readOnly:
            // A "read-only" descriptor that still reports an external side
            // effect or a file write is contradictory; fail closed instead of
            // trusting the effect label alone.
            guard !descriptor.isSideEffecting,
                  !descriptor.riskLabels.contains(.writesFiles) else {
                return .failure(PlanToolPolicyError(reason: .mutationNotAllowed, toolName: descriptor.name))
            }
            return .success(())
        case .internalState:
            // Closed two-name exception: a question is not implementation and
            // checklist.resetPlan clears only Floe-owned progress. Every other
            // internal-state tool (checklist.updatePlan, conversation.spawn,
            // jobs.cancel, memory.batchApply, …) stays unavailable in Plan;
            // the three exact memory writes were handled above.
            if [UserAskTool.name, TaskResetPlanTool.name].contains(descriptor.name),
               descriptor.executionBoundary == .mainRunOnly,
               !descriptor.isSideEffecting,
               descriptor.riskLabels.isEmpty,
               !descriptor.requiresHostScope {
                return .success(())
            }
            return .failure(PlanToolPolicyError(reason: .internalStateNotModelCallable, toolName: descriptor.name))
        case .mutating:
            return .failure(PlanToolPolicyError(reason: .mutationNotAllowed, toolName: descriptor.name))
        }
    }

    public func allowedDescriptors(
        from descriptors: [ToolCatalog.Descriptor]
    ) -> [ToolCatalog.Descriptor] {
        descriptors.filter {
            if case .success = decision(for: $0) { return true }
            return false
        }
    }

    public func denialResult(
        call: ToolCall,
        descriptor: ToolCatalog.Descriptor?
    ) -> ToolResult? {
        guard let descriptor else {
            return ToolResult(
                callID: call.id,
                status: .denied,
                outputSummary: "Plan mode denied unknown tool '\(call.toolName)'",
                outputDigest: ""
            )
        }
        guard case .failure(let error) = decision(for: descriptor) else { return nil }
        return ToolResult(
            callID: call.id,
            status: .denied,
            outputSummary: error.localizedDescription,
            outputDigest: ""
        )
    }
}

public struct PlanToolPolicyError: Error, Sendable, Codable, Hashable, LocalizedError {
    public var reason: PlanToolDenialReason
    public var toolName: String

    public init(reason: PlanToolDenialReason, toolName: String) {
        self.reason = reason
        self.toolName = toolName
    }

    public var errorDescription: String? {
        switch reason {
        case .mutationNotAllowed:
            "Plan mode is read-only; tool '\(toolName)' may change external state"
        case .internalStateNotModelCallable:
            "Floe internal draft state cannot be modified through tool '\(toolName)'"
        case .unknownTool:
            "Plan mode denied unknown tool '\(toolName)'"
        }
    }
}

/// Reusable executor-side guard for callers outside `FloeAgentRuntime`.
public struct PlanEnforcingToolExecutor: ToolExecutor {
    private let underlying: any ToolExecutor
    private let policy: PlanToolPolicy

    public init(underlying: any ToolExecutor, policy: PlanToolPolicy = PlanToolPolicy()) {
        self.underlying = underlying
        self.policy = policy
    }

    public func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        underlying.descriptor(named: name)
    }

    public var allDescriptors: [ToolCatalog.Descriptor] {
        underlying.allDescriptors
    }

    public func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        if let denial = policy.denialResult(call: call, descriptor: underlying.descriptor(named: call.toolName)) {
            return denial
        }
        return try await underlying.execute(call, context: context)
    }
}
