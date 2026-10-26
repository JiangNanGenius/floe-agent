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
public struct PlanToolPolicy: Sendable {
    public init() {}

    public func decision(for descriptor: ToolCatalog.Descriptor) -> Result<Void, PlanToolPolicyError> {
        switch descriptor.effect {
        case .readOnly:
            .success(())
        case .internalState:
            .failure(PlanToolPolicyError(reason: .internalStateNotModelCallable, toolName: descriptor.name))
        case .mutating:
            .failure(PlanToolPolicyError(reason: .mutationNotAllowed, toolName: descriptor.name))
        }
    }

    public func allowedDescriptors(
        from descriptors: [ToolCatalog.Descriptor]
    ) -> [ToolCatalog.Descriptor] {
        descriptors.filter { $0.effect.isAllowedInPlanMode }
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
